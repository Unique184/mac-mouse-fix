//
// --------------------------------------------------------------------------
// MFTableView.m
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2021
// Licensed under MIT
// --------------------------------------------------------------------------
//

#import "RemapTableView.h"

@implementation RemapTableView

- (instancetype)init {
    
    if (self = [super init]) {
        self.intercellSpacing = NSMakeSize(20,20);

    }
    return self;
}

// (?) Need this to make keystroke capture field first responder
// See https://stackoverflow.com/questions/29986224/editable-nstextfield-in-nstableview
//- (BOOL)validateProposedFirstResponder:(NSResponder *)responder forEvent:(NSEvent *)event {
//    return YES;
//}

//- (void)drawGridInClipRect:(NSRect)clipRect {
//    [NSColor.redColor setFill];
//    NSRectFill(clipRect);
//}

@end
