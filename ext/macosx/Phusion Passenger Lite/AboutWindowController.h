//
//  AboutWindowController.h
//  Phusion Passenger Lite
//
//  Created by Ninh Bui on 1/13/10.
//  Copyright 2010 Phusion v.o.f.. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface AboutWindowController : NSWindowController {
	NSURL *phusionURL;
	NSURL *phusionPassengerURL;
	IBOutlet NSTextField *versionLabel;
}

@property (readwrite, retain) NSURL *phusionURL;
@property (readwrite, retain) NSURL *phusionPassengerURL;
@property (readwrite, retain) IBOutlet NSTextField *versionLabel;

+(AboutWindowController *)sharedInstance;
-(IBAction)openPhusionURL:(id)sender;
-(IBAction)openPhusionPassengerURL:(id)sender;
@end
