/*
 * Copyright (C) 2019 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "WKDeferringGestureRecognizer.h"

#if PLATFORM(IOS_FAMILY)

#import <wtf/WeakObjCPtr.h>

@implementation WKDeferringGestureRecognizer {
    WeakObjCPtr<id <WKDeferringGestureRecognizerDelegate>> _deferringGestureDelegate;
}

- (instancetype)initWithDeferringGestureDelegate:(id <WKDeferringGestureRecognizerDelegate>)deferringGestureDelegate
{
    if (self = [super init])
        _deferringGestureDelegate = deferringGestureDelegate;
    return self;
}

- (id <WKDeferringGestureRecognizerDelegate>)deferringGestureDelegate
{
    return _deferringGestureDelegate.get().get();
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [super touchesBegan:touches withEvent:event];
    if ([_deferringGestureDelegate deferringGestureRecognizer:self shouldDeferGesturesAfterBeginningTouchesWithEvent:event])
        return;

    self.state = UIGestureRecognizerStateFailed;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [super touchesCancelled:touches withEvent:event];
    self.state = UIGestureRecognizerStateFailed;
}

- (void)setDefaultPrevented:(BOOL)defaultPrevented
{
    if (defaultPrevented)
        self.state = UIGestureRecognizerStateEnded;
    else
        self.state = UIGestureRecognizerStateFailed;
}

- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)preventingGestureRecognizer
{
    return NO;
}

- (BOOL)shouldDeferGestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
{
    return [_deferringGestureDelegate deferringGestureRecognizer:self shouldDeferOtherGestureRecognizer:gestureRecognizer];
}

@end

#endif // PLATFORM(IOS_FAMILY)
