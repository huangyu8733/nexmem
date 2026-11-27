package push

import (
	"context"
	"errors"
	"testing"
)

type recorder struct {
	calls []string
	err   error
}

func (r *recorder) PushSilent(ctx context.Context, account, token string) error {
	r.calls = append(r.calls, token)
	return r.err
}

func TestRouterRoutesByPrefix(t *testing.T) {
	apns, fcm, web := &recorder{}, &recorder{}, &recorder{}
	r := NewRouter(apns, fcm, web)
	cases := []struct {
		raw  string
		want string
		sink *recorder
	}{
		{"apns:abc123", "abc123", apns},
		{"fcm:tok123", "tok123", fcm},
		{"web:sub123", "sub123", web},
		{"legacy-token-without-prefix", "legacy-token-without-prefix", apns},
	}
	for _, tc := range cases {
		apns.calls, fcm.calls, web.calls = nil, nil, nil
		if err := r.PushSilent(context.Background(), "acct", tc.raw); err != nil {
			t.Fatalf("%s: %v", tc.raw, err)
		}
		if len(tc.sink.calls) != 1 || tc.sink.calls[0] != tc.want {
			t.Fatalf("%s: got %v, want [%s]", tc.raw, tc.sink.calls, tc.want)
		}
	}
}

func TestRouterUnconfiguredDoesNotLookLikeBadToken(t *testing.T) {
	r := NewRouter(nil, nil, nil)
	err := r.PushSilent(context.Background(), "acct", PrefixToken("fcm", "sometoken"))
	if !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("期望 ErrNotConfigured，实际 %v", err)
	}
	if errors.Is(err, ErrBadToken) {
		t.Fatal("未配置不能被当成坏令牌，否则令牌会被误删")
	}
}

func TestSplitAndPrefixToken(t *testing.T) {
	for _, p := range []string{"apns", "fcm", "web"} {
		platform, token := SplitToken(PrefixToken(p, "  abc  "))
		if platform != p || token != "abc" {
			t.Fatalf("%s: got (%s,%s)", p, platform, token)
		}
	}
	platform, token := SplitToken(" CUSTOM:xyz ")
	if platform != "apns" || token != "CUSTOM:xyz" {
		t.Fatalf("未知前缀应回退 apns，实际 (%q,%q)", platform, token)
	}
}

func TestFCMRequiresCredentials(t *testing.T) {
	if _, err := NewFCM(ServiceAccount{}); err == nil {
		t.Fatal("空服务账号应报错")
	}
}

func TestWebPushRequiresSubjectAndKey(t *testing.T) {
	if _, err := NewWebPush(WebPushConfig{}); err == nil {
		t.Fatal("空 VAPID 配置应报错")
	}
}
