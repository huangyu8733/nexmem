// gomobile 生成的 MobileEventSink 同时存在同名类与 protocol，Swift 无法
// 消歧（会优先解析为类并触发多继承错误）。这个 ObjC adapter 显式遵循
// protocol，Swift 侧只与它打交道，避免同名冲突与 go_seq_go_to_refnum 崩溃。
#import <Foundation/Foundation.h>
#import <Nexmem/Nexmem.h>

NS_ASSUME_NONNULL_BEGIN

@interface NexmemEventSink : NSObject <MobileEventSink>

/// Swift 侧设置回调，接收内核事件信封 JSON。
@property (nonatomic, copy, nullable) void (^onEventPayload)(NSString * _Nullable payload);

@end

NS_ASSUME_NONNULL_END
