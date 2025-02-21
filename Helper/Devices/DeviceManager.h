//
// --------------------------------------------------------------------------
// DeviceManager.h
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2019
// Licensed under MIT
// --------------------------------------------------------------------------
//

#import <Foundation/Foundation.h>
#import "MFDevice.h"

@interface DeviceManager : NSObject

+ (void)load_Manual;
+ (BOOL)devicesAreAttached;
+ (NSArray<MFDevice *> *)attachedDevices;

@end

