// 실제 장치 API의 독립 확인용이다. 창·입력·표시 지연 증거는 아니며 제품에는 링크하지 않는다.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
int main(void) { @autoreleasepool {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue=[device newCommandQueue];
    id<MTLCommandBuffer> command=[queue commandBuffer];
    id<MTLBuffer> buffer=[device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    if (!device || !queue || !command || !buffer) return 2;
    id<MTLBlitCommandEncoder> encoder=[command blitCommandEncoder];
    [encoder fillBuffer:buffer range:NSMakeRange(0,4096) value:0x5a];[encoder endEncoding];
    const uintptr_t identity=(uintptr_t)(__bridge void *)command;
    NSMutableDictionary *state=[NSMutableDictionary dictionary];
    dispatch_group_t group=dispatch_group_create();dispatch_group_enter(group);dispatch_group_enter(group);
    [command addScheduledHandler:^(id<MTLCommandBuffer> value) {
        @synchronized(state) { state[@"scheduled_same_object"]=@((uintptr_t)(__bridge void *)value==identity);state[@"scheduled_callback"]=@(CACurrentMediaTime()); }
        dispatch_group_leave(group);
    }];
    [command addCompletedHandler:^(id<MTLCommandBuffer> value) {
        @synchronized(state) {
            state[@"completed_same_object"]=@((uintptr_t)(__bridge void *)value==identity);
            state[@"kernel_start"]=@(value.kernelStartTime);state[@"kernel_end"]=@(value.kernelEndTime);
            state[@"gpu_start"]=@(value.GPUStartTime);state[@"gpu_end"]=@(value.GPUEndTime);
            state[@"completed_callback"]=@(CACurrentMediaTime());state[@"status"]=@((int)value.status);state[@"error"]=@(value.error!=nil);
        }
        dispatch_group_leave(group);
    }];
    const double before=CACurrentMediaTime();[command commit];const double returned=CACurrentMediaTime();
    if (dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))) return 3;
    BOOL bytes=YES;const uint8_t *data=buffer.contents;for (int i=0;i<4096;i++) if (data[i]!=0x5a) bytes=NO;
    state[@"commit"]=@(before);state[@"returned"]=@(returned);state[@"filled_bytes_correct"]=@(bytes);state[@"device"]=device.name;
    const BOOL api=[state[@"scheduled_same_object"] boolValue] && [state[@"completed_same_object"] boolValue] &&
        [state[@"status"] intValue]==4 && ![state[@"error"] boolValue] &&
        [state[@"kernel_start"] doubleValue]>0 && [state[@"kernel_end"] doubleValue]>=[state[@"kernel_start"] doubleValue] &&
        [state[@"gpu_start"] doubleValue]>=before && [state[@"gpu_end"] doubleValue]>=[state[@"gpu_start"] doubleValue] &&
        [state[@"completed_callback"] doubleValue]>=[state[@"gpu_end"] doubleValue];
    state[@"api_contract_correct"]=@(api);
    NSData *json=[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);
    return !bytes ? 4 : (api ? 0 : 5);
} }
