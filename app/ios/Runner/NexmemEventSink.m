#import "NexmemEventSink.h"

@implementation NexmemEventSink

- (void)onEvent:(NSString * _Nullable)payload {
    void (^handler)(NSString * _Nullable) = self.onEventPayload;
    if (handler != nil) {
        handler(payload);
    }
}

@end
