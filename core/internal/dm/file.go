package dm

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/libp2p/go-libp2p/core/network"
	"google.golang.org/protobuf/proto"

	nexmemv1 "github.com/nexmem/core/api/v1"
	filecrypto "github.com/nexmem/core/internal/crypto"
	"github.com/nexmem/core/internal/store"
	"github.com/nexmem/core/internal/wire"
)

const (
	// DefaultChunkSize 是文件分片大小：单帧（含签名与 GCM 标签）远小于 1 MiB 上限。
	DefaultChunkSize = 256 << 10
	// DefaultProgressInterval 是 transfer.progress 的最小上报间隔。
	DefaultProgressInterval = 200 * time.Millisecond
	// maxFileChunks 防止异常元数据导致过量分片。
	maxFileChunks = 1 << 20
	// fileMaxAttempts 是断点续传的最大尝试次数，含首次发送。
	fileMaxAttempts = 3
	// fileRetryDelay 是两次续传尝试之间的等待。
	fileRetryDelay = 500 * time.Millisecond
)

// 文件传输进度方向。
const (
	ProgressInbound  = 0
	ProgressOutbound = 1
)

// 文件传输语义错误。
var (
	ErrInvalidFile    = errors.New("文件不可读或不是普通文件")
	ErrFileTooLarge   = errors.New("文件分片数超过上限")
	ErrFileRejected   = errors.New("对端拒绝接收文件")
	ErrFileNotOffered = errors.New("未找到对应的文件消息")
)

// TransferProgress 对应契约中的 transfer.progress 事件。
type TransferProgress struct {
	MsgUUID   string
	Done      int64
	Total     int64
	Direction int
}

// SendFile 向对端发送一个文件：先投递携带附件元数据的文件消息并等待 ACK，
// 再在独立流上分片加密传输；分片使用随机 AES-256 密钥，密钥随附件元数据下发。
//
// 进度通过 Options.OnProgress 上报，按 Options.ProgressInterval（默认 200ms）节流，
// 传输完成时必定上报一次 Done==Total。
func (s *Service) SendFile(ctx context.Context, t Target, path, mime string) (string, error) {
	if !validAccountPub(t.AccountPub) {
		return "", ErrInvalidTarget
	}
	if bytes.Equal(t.AccountPub, s.account.Pub()) {
		return "", ErrSelfSend
	}
	if blocked, err := s.isBlocked(ctx, t.AccountPub); err != nil {
		return "", err
	} else if blocked {
		return "", ErrPeerBlocked
	}
	if t.PeerID == "" {
		return "", fmt.Errorf("%w: 缺少 PeerID", ErrPeerUnreached)
	}
	if !filepath.IsAbs(path) {
		return "", fmt.Errorf("%w: 需要绝对路径", ErrInvalidFile)
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrInvalidFile, err)
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 {
		return "", ErrInvalidFile
	}
	if ctx == nil {
		ctx = context.Background()
	}

	key, err := filecrypto.GenerateFileKey()
	if err != nil {
		return "", err
	}
	sum, err := hashFile(path)
	if err != nil {
		return "", err
	}
	chunkSize := s.chunkSize
	totalChunks := int((info.Size() + int64(chunkSize) - 1) / int64(chunkSize))
	if totalChunks > maxFileChunks {
		return "", ErrFileTooLarge
	}
	if mime == "" {
		mime = "application/octet-stream"
	}

	innerMsg := &nexmemv1.InnerMessage{
		Attachments: []*nexmemv1.Attachment{{
			Name:   filepath.Base(path),
			Size:   uint64(info.Size()),
			Mime:   mime,
			Sha256: sum,
			Key:    key,
		}},
	}
	inner, err := proto.Marshal(innerMsg)
	if err != nil {
		return "", fmt.Errorf("序列化附件元数据: %w", err)
	}
	// 本机副本额外记录绝对路径，供重启后 msg.list 回填 path（图片缩略图 / 文件定位）；
	// 上行帧仍使用不含 BlobRef 的 inner，避免把本机路径泄露给对端。
	localInner, err := proto.Marshal(&nexmemv1.InnerMessage{
		Attachments: []*nexmemv1.Attachment{{
			Name:    innerMsg.Attachments[0].GetName(),
			Size:    innerMsg.Attachments[0].GetSize(),
			Mime:    innerMsg.Attachments[0].GetMime(),
			Sha256:  innerMsg.Attachments[0].GetSha256(),
			Key:     innerMsg.Attachments[0].GetKey(),
			BlobRef: path,
		}},
	})
	if err != nil {
		return "", fmt.Errorf("序列化本机附件元数据: %w", err)
	}

	s.sendMu.Lock()
	convID := ConversationID(s.account.Pub(), t.AccountPub)
	ts := s.nextTimestamp()
	msgID, err := newUUIDv7(ts)
	if err != nil {
		s.sendMu.Unlock()
		return "", err
	}
	payload, err := proto.Marshal(&nexmemv1.DirectMessage{
		MsgUuid:         msgID,
		Timestamp:       ts,
		SenderAccount:   s.account.Pub(),
		ReceiverAccount: t.AccountPub,
		ConversationId:  []byte(convID),
		ContentType:     nexmemv1.ContentType_CONTENT_TYPE_FILE,
		Inner:           inner,
	})
	if err != nil {
		s.sendMu.Unlock()
		return msgID, fmt.Errorf("序列化文件消息: %w", err)
	}
	frame := &nexmemv1.Frame{
		Version: wire.Version,
		Type:    nexmemv1.FrameType_FRAME_TYPE_MSG,
		Payload: payload,
	}
	if err := wire.SignFrame(s.deviceKey, frame); err != nil {
		s.sendMu.Unlock()
		return msgID, err
	}
	if err := s.dao.EnsureConversation(ctx, store.Conversation{ID: convID, Kind: store.ConversationKindDM}); err != nil {
		s.sendMu.Unlock()
		return msgID, err
	}
	if err := s.dao.PutMessage(ctx, store.Message{
		MsgUUID:        msgID,
		ConversationID: convID,
		SenderAccount:  s.account.Pub(),
		SentAt:         ts,
		Direction:      store.DirectionOut,
		ContentType:    int(nexmemv1.ContentType_CONTENT_TYPE_FILE),
		BodyEnc:        localInner,
		State:          store.MessageStatePending,
		Raw:            payload,
		Body:           filepath.Base(path),
	}); err != nil {
		s.sendMu.Unlock()
		return msgID, err
	}
	offerErr := s.deliverWithRetry(ctx, t, frame, msgID)
	s.sendMu.Unlock()
	if offerErr != nil {
		s.markState(ctx, msgID, store.MessageStateFailed)
		if !errors.Is(offerErr, ErrPeerRejected) {
			if qerr := s.enqueueOutbox(ctx, t, frame, msgID); qerr != nil {
				return msgID, fmt.Errorf("%w（写入离线队列失败: %v）", offerErr, qerr)
			}
		}
		return msgID, offerErr
	}

	if err := s.transferFile(ctx, t, msgID, path, key, chunkSize, totalChunks, info.Size(), sum); err != nil {
		s.markState(ctx, msgID, store.MessageStateFailed)
		return msgID, err
	}

	s.markState(ctx, msgID, store.MessageStateSent)
	if err := s.dao.TouchConversation(ctx, convID, ts); err != nil {
		return msgID, err
	}
	return msgID, nil
}

// transferFile 在 /nexmem/dm-file/1.0.0 上完成文件分片传输。
// 传输中断时保留发送端消息与接收端半成品，按接收方上报的续传起点重试，
// 最多尝试 fileMaxAttempts 次；对端明确拒收不重试。
func (s *Service) transferFile(ctx context.Context, t Target, msgID, path string, key []byte, chunkSize, totalChunks int, size int64, sum []byte) error {
	var lastErr error
	for attempt := 1; attempt <= fileMaxAttempts; attempt++ {
		if attempt > 1 {
			timer := time.NewTimer(fileRetryDelay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return ctx.Err()
			case <-timer.C:
			}
		}
		err := s.transferFileOnce(ctx, t, msgID, path, key, chunkSize, totalChunks, size, sum)
		if err == nil {
			return nil
		}
		if errors.Is(err, ErrFileRejected) {
			return err
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		lastErr = err
	}
	return fmt.Errorf("文件传输 %d 次尝试均失败: %w", fileMaxAttempts, lastErr)
}

// transferFileOnce 完成一次分片传输：先发元数据并读取对端续传起点，
// 再只发送剩余分片，最后发完成帧并等待 ACK。接收方回 ACK 后返回。
func (s *Service) transferFileOnce(ctx context.Context, t Target, msgID, path string, key []byte, chunkSize, totalChunks int, size int64, sum []byte) error {
	if err := s.connect(ctx, t); err != nil {
		return err
	}
	streamCtx := network.WithAllowLimitedConn(ctx, "nexmem-dm-file")
	st, err := s.host.NewStream(streamCtx, t.PeerID, wire.PIDFile)
	if err != nil {
		return fmt.Errorf("%w: 打开文件流: %v", ErrPeerUnreached, err)
	}
	defer st.Close()

	cc, err := filecrypto.NewChunkCipher(key)
	if err != nil {
		return err
	}

	metaPayload, err := proto.Marshal(&nexmemv1.FileMeta{
		MsgUuid:       msgID,
		Name:          filepath.Base(path),
		Size:          uint64(size),
		ChunkSize:     uint32(chunkSize),
		TotalChunks:   uint32(totalChunks),
		Sha256:        sum,
		SenderAccount: s.account.Pub(),
	})
	if err != nil {
		return fmt.Errorf("序列化文件元数据: %w", err)
	}
	offer := &nexmemv1.Frame{
		Version: wire.Version,
		Type:    nexmemv1.FrameType_FRAME_TYPE_FILE_OFFER,
		Payload: metaPayload,
	}
	if err := wire.SignFrame(s.deviceKey, offer); err != nil {
		return err
	}
	if err := st.SetDeadline(time.Now().Add(streamTimeout)); err != nil {
		return fmt.Errorf("设置流超时: %w", err)
	}
	if err := wire.WriteFrame(st, offer); err != nil {
		return fmt.Errorf("发送文件元数据: %w", err)
	}

	stateFrame, err := wire.ReadFrame(st)
	if err != nil {
		return fmt.Errorf("等待文件状态: %w", err)
	}
	if err := wire.VerifyFrame(st.Conn().RemotePublicKey(), stateFrame); err != nil {
		return fmt.Errorf("%w: %v", ErrAckInvalid, err)
	}
	if stateFrame.Type != nexmemv1.FrameType_FRAME_TYPE_ACK {
		return fmt.Errorf("%w: 文件状态帧类型 %s", ErrAckInvalid, stateFrame.Type)
	}
	state := &nexmemv1.Ack{}
	if err := proto.Unmarshal(stateFrame.Payload, state); err != nil {
		return fmt.Errorf("%w: 解析文件状态: %v", ErrAckInvalid, err)
	}
	if state.MsgUuid != msgID {
		return fmt.Errorf("%w: 文件状态消息 ID 不匹配", ErrAckInvalid)
	}
	if state.Code == AckReject {
		return ErrFileRejected
	}
	if state.Code != AckOK {
		return fmt.Errorf("%w: 文件状态错误码 %d", ErrAckInvalid, state.Code)
	}
	startChunk := int(state.GetNextChunk())
	if startChunk < 0 || startChunk > totalChunks {
		return fmt.Errorf("%w: 续传分片越界 %d", ErrAckInvalid, startChunk)
	}

	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrInvalidFile, err)
	}
	defer f.Close()
	if startChunk > 0 {
		if _, err := f.Seek(int64(startChunk)*int64(chunkSize), io.SeekStart); err != nil {
			return fmt.Errorf("定位续传分片: %w", err)
		}
	}

	emitter := newProgressEmitter(s.onProgress, s.progressEvery)
	buf := make([]byte, chunkSize)
	for idx := startChunk; idx < totalChunks; idx++ {
		n, rerr := io.ReadFull(f, buf)
		if rerr != nil && rerr != io.ErrUnexpectedEOF && rerr != io.EOF {
			return fmt.Errorf("读取文件分片 %d: %w", idx, rerr)
		}
		if n == 0 {
			return fmt.Errorf("文件读取提前结束于分片 %d", idx)
		}
		chunkPayload, err := proto.Marshal(&nexmemv1.FileChunk{
			MsgUuid: msgID,
			Index:   uint32(idx),
			Data:    cc.Seal(uint32(idx), buf[:n]),
		})
		if err != nil {
			return fmt.Errorf("序列化分片 %d: %w", idx, err)
		}
		cf := &nexmemv1.Frame{
			Version: wire.Version,
			Type:    nexmemv1.FrameType_FRAME_TYPE_FILE_CHUNK,
			Payload: chunkPayload,
		}
		if err := wire.SignFrame(s.deviceKey, cf); err != nil {
			return err
		}
		if err := st.SetDeadline(time.Now().Add(streamTimeout)); err != nil {
			return fmt.Errorf("设置分片超时: %w", err)
		}
		if err := wire.WriteFrame(st, cf); err != nil {
			return fmt.Errorf("发送分片 %d: %w", idx, err)
		}
		done := int64(idx+1) * int64(chunkSize)
		if done > size {
			done = size
		}
		emitter.emit(TransferProgress{MsgUUID: msgID, Done: done, Total: size, Direction: ProgressOutbound})
	}

	donePayload, err := proto.Marshal(&nexmemv1.FileDone{MsgUuid: msgID, Sha256: sum})
	if err != nil {
		return fmt.Errorf("序列化完成帧: %w", err)
	}
	doneFrame := &nexmemv1.Frame{
		Version: wire.Version,
		Type:    nexmemv1.FrameType_FRAME_TYPE_FILE_DONE,
		Payload: donePayload,
	}
	if err := wire.SignFrame(s.deviceKey, doneFrame); err != nil {
		return err
	}
	if err := st.SetDeadline(time.Now().Add(streamTimeout)); err != nil {
		return fmt.Errorf("设置完成帧超时: %w", err)
	}
	if err := wire.WriteFrame(st, doneFrame); err != nil {
		return fmt.Errorf("发送完成帧: %w", err)
	}

	ackFrame, err := wire.ReadFrame(st)
	if err != nil {
		return fmt.Errorf("等待文件 ACK: %w", err)
	}
	if err := wire.VerifyFrame(st.Conn().RemotePublicKey(), ackFrame); err != nil {
		return fmt.Errorf("%w: %v", ErrAckInvalid, err)
	}
	if ackFrame.Type != nexmemv1.FrameType_FRAME_TYPE_ACK {
		return fmt.Errorf("%w: 文件 ACK 帧类型 %s", ErrAckInvalid, ackFrame.Type)
	}
	ack := &nexmemv1.Ack{}
	if err := proto.Unmarshal(ackFrame.Payload, ack); err != nil {
		return fmt.Errorf("%w: 解析文件 ACK: %v", ErrAckInvalid, err)
	}
	if ack.MsgUuid != msgID {
		return fmt.Errorf("%w: 文件 ACK 消息 ID 不匹配", ErrAckInvalid)
	}
	switch ack.Code {
	case AckOK:
		emitter.emit(TransferProgress{MsgUUID: msgID, Done: size, Total: size, Direction: ProgressOutbound})
		return nil
	case AckReject:
		return ErrFileRejected
	default:
		return fmt.Errorf("%w: 文件 ACK 错误码 %d", ErrAckInvalid, ack.Code)
	}
}

// handleFileStream 处理入站文件流：校验元数据与已收文件消息 → 分片解密落盘 → 校验摘要 → 回 ACK。
func (s *Service) handleFileStream(st network.Stream) {
	defer st.Close()
	_ = st.SetDeadline(time.Now().Add(streamTimeout))

	frame, err := wire.ReadFrame(st)
	if err != nil {
		return
	}
	if frame.Version != wire.Version || frame.Type != nexmemv1.FrameType_FRAME_TYPE_FILE_OFFER {
		s.writeAck(st, "", AckReject)
		return
	}
	if err := wire.VerifyFrame(st.Conn().RemotePublicKey(), frame); err != nil {
		return
	}
	meta := &nexmemv1.FileMeta{}
	if err := proto.Unmarshal(frame.Payload, meta); err != nil {
		s.writeAck(st, "", AckReject)
		return
	}
	att, path, err := s.prepareInboundFile(context.Background(), meta)
	if err != nil {
		s.writeAck(st, meta.GetMsgUuid(), AckReject)
		return
	}
	tmpPath := path + filePartSuffix
	metaPath := path + fileMetaSuffix

	cc, err := filecrypto.NewChunkCipher(att.GetKey())
	if err != nil {
		s.writeAck(st, meta.GetMsgUuid(), AckReject)
		return
	}

	startChunk, f, hasher, err := openInboundPartial(tmpPath, metaPath, meta, att.GetSha256())
	if err != nil {
		s.writeAck(st, meta.GetMsgUuid(), AckReject)
		return
	}
	defer f.Close()

	if err := s.writeFileState(st, meta.GetMsgUuid(), uint32(startChunk)); err != nil {
		return
	}

	total := int(meta.GetTotalChunks())
	emitter := newProgressEmitter(s.onProgress, s.progressEvery)
	written := int64(startChunk) * int64(meta.GetChunkSize())
	if written > int64(meta.GetSize()) {
		written = int64(meta.GetSize())
	}
	if startChunk > 0 {
		// 续传时先上报已恢复进度，UI 不会从 0 重新开始。
		emitter.emit(TransferProgress{
			MsgUUID:   meta.GetMsgUuid(),
			Done:      written,
			Total:     int64(meta.GetSize()),
			Direction: ProgressInbound,
		})
	}
	for idx := startChunk; idx < total; idx++ {
		if err := st.SetDeadline(time.Now().Add(streamTimeout)); err != nil {
			return
		}
		cf, err := wire.ReadFrame(st)
		if err != nil {
			return
		}
		if err := wire.VerifyFrame(st.Conn().RemotePublicKey(), cf); err != nil {
			s.writeAck(st, meta.GetMsgUuid(), AckReject)
			return
		}
		if cf.Type != nexmemv1.FrameType_FRAME_TYPE_FILE_CHUNK {
			s.writeAck(st, meta.GetMsgUuid(), AckReject)
			return
		}
		chunk := &nexmemv1.FileChunk{}
		if err := proto.Unmarshal(cf.Payload, chunk); err != nil {
			s.writeAck(st, meta.GetMsgUuid(), AckReject)
			return
		}
		if chunk.GetMsgUuid() != meta.GetMsgUuid() || int(chunk.GetIndex()) != idx {
			s.writeAck(st, meta.GetMsgUuid(), AckReject)
			return
		}
		plain, err := cc.Open(chunk.GetIndex(), chunk.GetData())
		if err != nil {
			s.writeAck(st, meta.GetMsgUuid(), AckReject)
			return
		}
		if _, err := f.Write(plain); err != nil {
			s.writeAck(st, meta.GetMsgUuid(), AckReject)
			return
		}
		_, _ = hasher.Write(plain)
		written += int64(len(plain))
		emitter.emit(TransferProgress{
			MsgUUID:   meta.GetMsgUuid(),
			Done:      written,
			Total:     int64(meta.GetSize()),
			Direction: ProgressInbound,
		})
		if s.fileInterrupt != nil && s.fileInterrupt(idx) {
			// 测试注入的断流：重置流并保留半成品与元数据，等待发送端续传。
			_ = st.Reset()
			return
		}
	}

	doneFrame, err := wire.ReadFrame(st)
	if err != nil {
		return
	}
	if err := wire.VerifyFrame(st.Conn().RemotePublicKey(), doneFrame); err != nil {
		s.writeAck(st, meta.GetMsgUuid(), AckReject)
		return
	}
	if doneFrame.Type != nexmemv1.FrameType_FRAME_TYPE_FILE_DONE {
		s.writeAck(st, meta.GetMsgUuid(), AckReject)
		return
	}
	done := &nexmemv1.FileDone{}
	if err := proto.Unmarshal(doneFrame.Payload, done); err != nil {
		s.writeAck(st, meta.GetMsgUuid(), AckReject)
		return
	}
	if done.GetMsgUuid() != meta.GetMsgUuid() || !bytes.Equal(done.GetSha256(), att.GetSha256()) ||
		!bytes.Equal(hasher.Sum(nil), att.GetSha256()) || written != int64(att.GetSize()) {
		// 半成品内容不可信时整份丢弃，下一次尝试从 0 重传。
		_ = f.Close()
		removePartialFiles(tmpPath, metaPath)
		s.writeAck(st, meta.GetMsgUuid(), AckReject)
		return
	}

	if err := f.Close(); err != nil {
		s.writeAck(st, meta.GetMsgUuid(), AckReject)
		return
	}
	if err := os.Rename(tmpPath, path); err != nil {
		removePartialFiles(tmpPath, metaPath)
		s.writeAck(st, meta.GetMsgUuid(), AckReject)
		return
	}
	_ = os.Remove(metaPath)
	if err := s.attachInboundFile(context.Background(), meta.GetMsgUuid(), path); err != nil {
		s.writeAck(st, meta.GetMsgUuid(), AckReject)
		return
	}
	emitter.emit(TransferProgress{
		MsgUUID:   meta.GetMsgUuid(),
		Done:      written,
		Total:     int64(meta.GetSize()),
		Direction: ProgressInbound,
	})
	s.writeAck(st, meta.GetMsgUuid(), AckOK)
}

// prepareInboundFile 校验文件流元数据与已入库的文件消息一致，并返回附件与落盘路径。
func (s *Service) prepareInboundFile(ctx context.Context, meta *nexmemv1.FileMeta) (*nexmemv1.Attachment, string, error) {
	if meta.GetMsgUuid() == "" || meta.GetSize() == 0 || meta.GetChunkSize() == 0 || meta.GetTotalChunks() == 0 {
		return nil, "", ErrFileNotOffered
	}
	if meta.GetTotalChunks() > maxFileChunks ||
		int64(meta.GetChunkSize())*int64(meta.GetTotalChunks()) < int64(meta.GetSize()) {
		return nil, "", ErrFileNotOffered
	}
	if !validAccountPub(meta.GetSenderAccount()) || bytes.Equal(meta.GetSenderAccount(), s.account.Pub()) {
		return nil, "", ErrFileNotOffered
	}
	msg, err := s.dao.GetMessage(ctx, meta.GetMsgUuid())
	if err != nil || msg.Direction != store.DirectionIn ||
		msg.ContentType != int(nexmemv1.ContentType_CONTENT_TYPE_FILE) ||
		!bytes.Equal(msg.SenderAccount, meta.GetSenderAccount()) {
		return nil, "", ErrFileNotOffered
	}
	inner := &nexmemv1.InnerMessage{}
	if err := proto.Unmarshal(msg.BodyEnc, inner); err != nil || !validFileAttachment(inner) {
		return nil, "", ErrFileNotOffered
	}
	att := inner.Attachments[0]
	if att.GetSize() != meta.GetSize() || !bytes.Equal(att.GetSha256(), meta.GetSha256()) {
		return nil, "", ErrFileNotOffered
	}
	if err := os.MkdirAll(s.inboxDir, 0o700); err != nil {
		return nil, "", err
	}
	return att, filepath.Join(s.inboxDir, meta.GetMsgUuid()+"_"+sanitizeFileName(att.GetName())), nil
}

// attachInboundFile 把本地落盘路径写回附件元数据，供 UI 打开文件。
func (s *Service) attachInboundFile(ctx context.Context, msgID, path string) error {
	msg, err := s.dao.GetMessage(ctx, msgID)
	if err != nil {
		return err
	}
	inner := &nexmemv1.InnerMessage{}
	if err := proto.Unmarshal(msg.BodyEnc, inner); err != nil {
		return err
	}
	if !validFileAttachment(inner) {
		return ErrFileNotOffered
	}
	inner.Attachments[0].BlobRef = path
	body, err := proto.Marshal(inner)
	if err != nil {
		return err
	}
	msg.BodyEnc = body
	msg.State = store.MessageStateReceived
	msg.Body = inner.Attachments[0].GetName()
	return s.dao.PutMessage(ctx, *msg)
}

func (s *Service) writeFileState(st network.Stream, msgID string, next uint32) error {
	payload, err := proto.Marshal(&nexmemv1.Ack{
		MsgUuid:   msgID,
		Code:      AckOK,
		At:        time.Now().UnixMilli(),
		NextChunk: next,
	})
	if err != nil {
		return err
	}
	frame := &nexmemv1.Frame{
		Version: wire.Version,
		Type:    nexmemv1.FrameType_FRAME_TYPE_ACK,
		Payload: payload,
	}
	if err := wire.SignFrame(s.deviceKey, frame); err != nil {
		return err
	}
	return wire.WriteFrame(st, frame)
}

// hashFile 计算整文件 SHA-256。
func hashFile(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidFile, err)
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return nil, fmt.Errorf("计算文件摘要: %w", err)
	}
	return h.Sum(nil), nil
}

// defaultInboxDir 返回接收文件的默认目录。
func defaultInboxDir() string {
	if dir, err := os.UserCacheDir(); err == nil {
		return filepath.Join(dir, "nexmem", "inbox")
	}
	return filepath.Join(os.TempDir(), "nexmem-inbox")
}

// sanitizeFileName 去掉路径分隔符与 Windows 非法字符，避免越界落盘。
func sanitizeFileName(name string) string {
	name = filepath.Base(name)
	name = strings.Map(func(r rune) rune {
		switch r {
		case '<', '>', ':', '"', '/', '\\', '|', '?', '*':
			return '_'
		}
		if r < 0x20 {
			return '_'
		}
		return r
	}, name)
	if name == "" || name == "." || name == ".." {
		return "file"
	}
	return name
}

// progressEmitter 按固定间隔节流进度回调，完成事件不节流。
type progressEmitter struct {
	cb       func(TransferProgress)
	interval time.Duration
	last     time.Time
	now      func() time.Time
}

func newProgressEmitter(cb func(TransferProgress), interval time.Duration) *progressEmitter {
	return &progressEmitter{cb: cb, interval: interval, now: time.Now}
}

func (e *progressEmitter) emit(p TransferProgress) {
	if e.cb == nil {
		return
	}
	now := e.now()
	if p.Done < p.Total && !e.last.IsZero() && now.Sub(e.last) < e.interval {
		return
	}
	e.last = now
	e.cb(p)
}
