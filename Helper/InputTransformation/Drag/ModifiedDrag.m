//
// --------------------------------------------------------------------------
// ModifyingActions.m
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2020
// Licensed under MIT
// --------------------------------------------------------------------------
//

#import "Constants.h"

#import "ModifiedDrag.h"
#import "ScrollModifiers.h"
#import "TouchSimulator.h"
#import "GestureScrollSimulator.h"
#import "ModifierManager.h"

#import "SubPixelator.h"
#import <Cocoa/Cocoa.h>

#import "Utility_Transformation.h"
#import "SharedMessagePort.h"
#import "TransformationManager.h"
#import "SharedUtility.h"

#import "CGSSpace.h"

#import <Cocoa/Cocoa.h>

@implementation ModifiedDrag

struct ModifiedDragState {
    CFMachPortRef eventTap;
    int64_t usageThreshold;
    
    MFStringConstant type;

    MFModifiedInputActivationState activationState;
    MFDevice *modifiedDevice;
    
    CGPoint origin;
    MFVector originOffset;
    MFAxis usageAxis;
    IOHIDEventPhaseBits phase;
    
    SubPixelator *subPixelatorX;
    SubPixelator *subPixelatorY;
    
    MFMouseButtonNumber fakeDragButtonNumber; // Button number. Only used with modified drag of type kMFModifiedDragTypeFakeDrag.
    NSDictionary *addModePayload; // Payload to send to the mainApp. Only used with modified drag of type kMFModifiedDragTypeAddModeFeedback.
};

+ (NSString *)modifiedDragStateDescription:(struct ModifiedDragState)drag {
    NSString *output = @"";
    @try {
        output = [NSString stringWithFormat:
        @"\n\
        eventTap: %@\n\
        usageThreshold: %lld\n\
        type: %@\n\
        activationState: %u\n\
        modifiedDevice: \n%@\n\
        origin: (%f, %f)\n\
        originOffset: (%f, %f)\n\
        usageAxis: %u\n\
        phase: %hu\n\
        subPixelatorX: %@\n\
        subPixelatorY: %@\n\
        fakeDragButtonNumber: %u\n\
        addModePayload: %@\n",
                  drag.eventTap, drag.usageThreshold, drag.type, drag.activationState, drag.modifiedDevice, drag.origin.x, drag.origin.y, drag.originOffset.x, drag.originOffset.y, drag.usageAxis, drag.phase, drag.subPixelatorX, drag.subPixelatorY, drag.fakeDragButtonNumber, drag.addModePayload
                  ];
    } @catch (NSException *exception) {
        NSLog(@"Exception while generating string description of ModifiedDragState: %@", exception);
    }
    return output;
}

static struct ModifiedDragState _drag;
#define inputIsPointerMovement YES
int16_t _nOfSpaces = 1;

// There are two different modes for how we receive mouse input, toggle to switch between the two for testing
// Set to no, if you want input to be raw mouse input, set to yes if you want input to be mouse pointer delta
// Raw input has better performance (?) and allows for blocking mouse pointer movement. Mouse pointer input makes all the animation follow the pointer, but it has some issues with the pointer jumping when the framerate is low which I'm not quite sure how to fix.
//      When the pointer jumps that sometimes leads to scrolling in random directions and stuff.

+ (void)load_Manual {
    
    // Setup input callback and related
    if (inputIsPointerMovement) {
        // Create mouse pointer moved input callback
        if (_drag.eventTap == nil) {
            
            CGEventTapLocation location = kCGHIDEventTap;
            CGEventTapPlacement placement = kCGHeadInsertEventTap;
            CGEventTapOptions option = kCGEventTapOptionDefault;
            CGEventMask mask = CGEventMaskBit(kCGEventOtherMouseDragged) | CGEventMaskBit(kCGEventMouseMoved); // kCGEventMouseMoved is only necessary for keyboard-only drag-modification (which we've disable because it had other problems), and maybe for AddMode to work.
            mask = mask | CGEventMaskBit(kCGEventLeftMouseDragged) | CGEventMaskBit(kCGEventRightMouseDragged); // This is necessary for modified drag to work during a left/right click and drag. Concretely I added this to make drag and drop work. For that we only need the kCGEventLeftMouseDragged. Adding kCGEventRightMouseDragged is probably completely unnecessary. Not sure if there are other concrete applications outside of drag and drop.
            
            CFMachPortRef eventTap = [Utility_Transformation createEventTapWithLocation:location mask:mask option:option placement:placement callback:eventTapCallBack];
            
            _drag.eventTap = eventTap;
        }
        _drag.usageThreshold = 7; // 20
    } else {
        _drag.usageThreshold = 50;
    }
}

+ (void)initializeDragWithModifiedDragDict:(NSDictionary *)dict onDevice:(MFDevice *)dev {
    
    // Get values from dict
    MFStringConstant type = dict[kMFModifiedDragDictKeyType];
    MFMouseButtonNumber fakeDragButtonNumber = -1;
    if ([type isEqualToString:kMFModifiedDragTypeFakeDrag]) {
        fakeDragButtonNumber = ((NSNumber *)dict[kMFModifiedDragDictKeyFakeDragVariantButtonNumber]).intValue;
    }
    // Prepare payload to send to mainApp during AddMode. See TransformationManager -> AddMode for context
    NSMutableDictionary *payload = nil;
    if ([type isEqualToString:kMFModifiedDragTypeAddModeFeedback]){
        payload = dict.mutableCopy;
        [payload removeObjectForKey:kMFModifiedDragDictKeyType];
    }
    
    #if DEBUG
        NSLog(@"INITIALIZING MODIFIED DRAG WITH TYPE %@ ON DEVICE %@", type, dev);
    #endif
    
    // Init _drag struct
    _drag.modifiedDevice = dev;
    _drag.activationState = kMFModifiedInputActivationStateInitialized;
    _drag.type = type;
    _drag.origin = Utility_Transformation.CGMouseLocationWithoutEvent;
    _drag.originOffset = (MFVector){0};
    _drag.subPixelatorX = [SubPixelator alloc];
    _drag.subPixelatorY = [SubPixelator alloc];
    _drag.fakeDragButtonNumber = fakeDragButtonNumber;
    _drag.addModePayload = payload;
    
    if (inputIsPointerMovement) {
        CGEventTapEnable(_drag.eventTap, true);
    } else {
        [dev receiveAxisInputAndDoSeizeDevice:NO];
    }
}

static CGEventRef __nullable eventTapCallBack(CGEventTapProxy proxy, CGEventType type, CGEventRef  event, void * __nullable userInfo) {
    
    // Re-enable on timeout (Not sure if this ever times out)
    if (type == kCGEventTapDisabledByTimeout) {
        NSLog(@"ButtonInputReceiver eventTap timed out. Re-enabling.");
        CGEventTapEnable(_drag.eventTap, true);
    }
    
    int64_t dx = CGEventGetIntegerValueField(event, kCGMouseEventDeltaX);
    int64_t dy = CGEventGetIntegerValueField(event, kCGMouseEventDeltaY);
    [ModifiedDrag handleMouseInputWithDeltaX:dx deltaY:dy event:event];
    
    return NULL; // Sending event or NULL here doesn't seem to make a difference. If you alter the event and send that it does have an effect though
}

+ (void)handleMouseInputWithDeltaX:(int64_t)deltaX deltaY:(int64_t)deltaY event:(CGEventRef)event {
    
    MFModifiedInputActivationState st = _drag.activationState;
    
#if DEBUG
//    NSLog(@"Handling mouse input. dx: %lld, dy: %lld, activationState: %@", deltaX, deltaY, @(st));
#endif
            
    if (st == kMFModifiedInputActivationStateNone) {
        // Disabling the callback triggers this function one more time apparently, aside form that case, this should never happen I think
    } else if (st == kMFModifiedInputActivationStateInitialized) {
        handleMouseInputWhileInitialized(deltaX, deltaY);
    } else if (st == kMFModifiedInputActivationStateInUse) {
        handleMouseInputWhileInUse(deltaX, deltaY, event);
    }
}
static void handleMouseInputWhileInitialized(int64_t deltaX, int64_t deltaY) {
    
    _drag.originOffset.x += deltaX;
    _drag.originOffset.y += deltaY;
    
    MFVector ofs = _drag.originOffset;
    
    // Activate the modified drag if the mouse has been moved far enough from the point where the drag started
    if (MAX(fabs(ofs.x), fabs(ofs.y)) > _drag.usageThreshold) {
        
        MFDevice *dev = _drag.modifiedDevice;
        if (inputIsPointerMovement) {
            [NSCursor.closedHandCursor push]; // Doesn't work for some reason
        } else {
            if ([_drag.type isEqualToString:kMFModifiedDragTypeTwoFingerSwipe]) { // Only seize when drag scrolling // TODO: Would be cleaner to call this further down where we check for kMFModifiedDragVariantTwoFingerSwipe anyways. Does that work too?
                [dev receiveAxisInputAndDoSeizeDevice:YES];
            }
        }
        _drag.activationState = kMFModifiedInputActivationStateInUse; // Activate modified drag input!
        [ModifierManager handleModifiersHaveHadEffect:dev.uniqueID];
        
        if (fabs(ofs.x) < fabs(ofs.y)) {
            _drag.usageAxis = kMFAxisVertical;
        } else {
            _drag.usageAxis = kMFAxisHorizontal;
        }
        
        if ([_drag.type isEqualToString:kMFModifiedDragTypeThreeFingerSwipe]) {
            _drag.phase = kIOHIDEventPhaseBegan;
            
            /// Get number of spaces
            ///     for use in `handleMouseInputWhileInUse()`. Getting it here for performance reasons. Not sure if significant.
            CFArrayRef spaces = CGSCopySpaces(CGSMainConnectionID(), CGSSpaceIncludesUser | CGSSpaceIncludesOthers | CGSSpaceIncludesCurrent);
            /// Full screen spaces appear twice for some reason so we need to filter duplicates
            NSSet *uniqueSpaces = [NSSet setWithArray:(__bridge NSArray *)spaces];
            _nOfSpaces = uniqueSpaces.count;
            
            CFRelease(spaces);
            
        } else if ([_drag.type isEqualToString:kMFModifiedDragTypeTwoFingerSwipe]) {
            //                [GestureScrollSimulator postGestureScrollEventWithGestureDeltaX:0.0 deltaY:0.0 phase:kIOHIDEventPhaseMayBegin];
            // ^ Always sending this at the start breaks swiping between pages on some websites (Google search results)
            _drag.phase = kIOHIDEventPhaseBegan;
        } else if ([_drag.type isEqualToString:kMFModifiedDragTypeFakeDrag]) {
            
            [Utility_Transformation postMouseButton:_drag.fakeDragButtonNumber down:YES];
        } else if ([_drag.type isEqualToString:kMFModifiedDragTypeAddModeFeedback]) {
            if (_drag.addModePayload != nil) {
                if ([TransformationManager addModePayloadIsValid:_drag.addModePayload]) {
                    [SharedMessagePort sendMessage:@"addModeFeedback" withPayload:_drag.addModePayload expectingReply:NO];
                    disableMouseTracking(); // Not sure if should be here
                }
            } else {
                @throw [NSException exceptionWithName:@"InvalidAddModeFeedbackPayload" reason:@"_drag.addModePayload is nil. Something went wrong!" userInfo:nil]; // Throw exception to cause crash
            }
        }
    }
}
// Only passing in event to obtain event location to get slightly better behaviour for fakeDrag
void handleMouseInputWhileInUse(int64_t deltaX, int64_t deltaY, CGEventRef event) {
    
    double twoFingerScale;
    double threeFingerScaleH;
    double threeFingerScaleV;
    
    /*
     Horizontal dockSwipe scaling
        This makes horizontal dockSwipes (switch between spaces) follow the pointer exactly. (If everything works)
        I arrived at these value through testing documented in the NotePlan note "MMF - Scraps - Testing DockSwipe scaling"
        TODO: Test this on a vertical screen
     */
    
    double originOffsetForOneSpace = _nOfSpaces == 1 ? 2.0 : 1.0 + (1.0 / (_nOfSpaces-1));
    /// ^ I've seen this be: 1.25, 1.5, 2.0. Not sure why. Restarting, attaching displays, or changing UI scaling don't seem to change it from my testing. It just randomly changes after a few weeks.
    ///     I think I finally see the pattern:
    ///         It's 2.0 for 2 spaces
    ///         It's 1.5 for 3 spaces
    ///         It's 1.25 for 5 spaces
    ///         So the patterns is: 1 + 1 / (nOfSpaces-1)
    ///            (Except for 1 cause you can't divide by zero)
    
    CGFloat screenWidth = NSScreen.mainScreen.frame.size.width;
    double spaceSeparatorWidth = 63;
    threeFingerScaleH = threeFingerScaleV = originOffsetForOneSpace / (screenWidth + spaceSeparatorWidth);
    
    // Vertical dockSwipe scaling
    // We should maybe use screenHeight to scale vertical dockSwipes (Mission Control and App Windows), but since they don't follow the mouse pointer anyways, this is fine;
    threeFingerScaleV *= 1.0;
    
    /*
     scrollSwipe scaling
        A scale of 1.0 will make the pixel based animations (normal scrolling) follow the mouse pointer.
        Gesture based animations (swiping between pages in Safari etc.) seem to be scaled separately such that swiping 3/4 (or so) of the way across the Trackpad equals one whole page. No matter how wide the page is.
        So to scale the gesture deltas such that the page-change-animations follow the mouse pointer exactly, we'd somehow have to get the width of the underlying scrollview. This might be possible using the _systemWideAXUIElement we created in ScrollControl, but it'll probably be really slow.
    */
    twoFingerScale = 1.0;
    
    if ([_drag.type isEqualToString:kMFModifiedDragTypeThreeFingerSwipe]) {
        if (_drag.usageAxis == kMFAxisHorizontal) {
            double delta = -deltaX * threeFingerScaleH;
            [TouchSimulator postDockSwipeEventWithDelta:delta type:kMFDockSwipeTypeHorizontal phase:_drag.phase];
        } else if (_drag.usageAxis == kMFAxisVertical) {
            double delta = deltaY * threeFingerScaleV;
            [TouchSimulator postDockSwipeEventWithDelta:delta type:kMFDockSwipeTypeVertical phase:_drag.phase];
        }
//        _drag.phase = kIOHIDEventPhaseChanged;
    } else if ([_drag.type isEqualToString:kMFModifiedDragTypeTwoFingerSwipe]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.0 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [GestureScrollSimulator postGestureScrollEventWithDeltaX:deltaX*twoFingerScale deltaY:deltaY*twoFingerScale phase:_drag.phase isGestureDelta:!inputIsPointerMovement];
        });
    } else if ([_drag.type isEqualToString:kMFModifiedDragTypeFakeDrag]) {
        CGPoint location;
        if (event) {
            location = CGEventGetLocation(event); // I feel using `event` passed in from eventTap here makes things slighly more responsive that using `Utility_Transformation.CGMouseLocationWithoutEvent`
        } else {
            location = Utility_Transformation.CGMouseLocationWithoutEvent;
        }
        CGMouseButton button = [SharedUtility CGMouseButtonFromMFMouseButtonNumber:_drag.fakeDragButtonNumber];
        CGEventRef draggedEvent = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseDragged, location, button);
        CGEventPost(kCGSessionEventTap, draggedEvent);
        CFRelease(draggedEvent);
    }
    _drag.phase = kIOHIDEventPhaseChanged;
}

+ (void)deactivate {
    
#if DEBUG
//    NSLog(@"Deactivating modified drag with state: %@", [self modifiedDragStateDescription:_drag]);
#endif
    
    if (_drag.activationState == kMFModifiedInputActivationStateNone) return;
    
    disableMouseTracking(); // Moved this up here instead of at the end of the function to minimize mouseMovedOrDraggedCallback() being called when we don't need that anymore. Not sure if it makes a difference.
    
    if (_drag.activationState == kMFModifiedInputActivationStateInUse) {
        handleDeactivationWhileInUse();
    }
    _drag.activationState = kMFModifiedInputActivationStateNone;
}

static void handleDeactivationWhileInUse() {
    if ([_drag.type isEqualToString:kMFModifiedDragTypeThreeFingerSwipe]) {
        struct ModifiedDragState localDrag = _drag;
        if (localDrag.usageAxis == kMFAxisHorizontal) {
            [TouchSimulator postDockSwipeEventWithDelta:0.0 type:kMFDockSwipeTypeHorizontal phase:kIOHIDEventPhaseEnded];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [TouchSimulator postDockSwipeEventWithDelta:0.0 type:kMFDockSwipeTypeHorizontal phase:kIOHIDEventPhaseEnded];
            });
            // ^ The inital dockSwipe event we post will be ignored by the system when it is under load (I called this the "stuck bug" in other places). Sending the event again with a delay of 200ms (0.2s) gets it unstuck almost always. Sending the event twice gives us the best of both responsiveness and reliability.
        } else if (localDrag.usageAxis == kMFAxisVertical) {
            [TouchSimulator postDockSwipeEventWithDelta:0.0 type:kMFDockSwipeTypeVertical phase:kIOHIDEventPhaseEnded];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [TouchSimulator postDockSwipeEventWithDelta:0.0 type:kMFDockSwipeTypeVertical phase:kIOHIDEventPhaseEnded];
            });
        }
    } else if ([_drag.type isEqualToString:kMFModifiedDragTypeTwoFingerSwipe]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.0 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [GestureScrollSimulator postGestureScrollEventWithDeltaX:0 deltaY:0 phase:kIOHIDEventPhaseEnded isGestureDelta:!inputIsPointerMovement];
        });
    } else if ([_drag.type isEqualToString:kMFModifiedDragTypeFakeDrag]) {
        [Utility_Transformation postMouseButton:_drag.fakeDragButtonNumber down:NO];
    } else if ([_drag.type isEqualToString:kMFModifiedDragTypeAddModeFeedback]) {
        if ([TransformationManager addModePayloadIsValid:_drag.addModePayload]) { // If it's valid, then we sent the payload off to the MainApp
            [TransformationManager disableAddMode]; // Why disable it here and not when sending the payload?
        }
    }
}

#pragma mark - Helper functions

static void disableMouseTracking() {
    if (inputIsPointerMovement) {
        CGEventTapEnable(_drag.eventTap, false);
        [NSCursor.closedHandCursor pop];
    } else {
        [_drag.modifiedDevice receiveOnlyButtonInput];
    }
}


@end
