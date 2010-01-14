//
//  AboutWindowController.m
//  Phusion Passenger Lite
//
//  Created by Ninh Bui on 1/13/10.
//  Copyright 2010 Phusion v.o.f.. All rights reserved.
//

#import "AboutWindowController.h"
#import "common/Version.h"

@implementation AboutWindowController

@synthesize phusionURL;
@synthesize phusionPassengerURL;
@synthesize versionLabel;

static AboutWindowController *sharedInstance = nil;

+(AboutWindowController *)sharedInstance {
	if(sharedInstance) {
		return sharedInstance;
	}
	
	@synchronized(self) {
		if (sharedInstance == nil) {
			sharedInstance = [[AboutWindowController alloc] 
							  initWithWindowNibName:@"About"];
			
			NSURL *phusionURL = [[NSURL alloc]
								 initWithString:@"http://phusion.nl"];
			[sharedInstance setPhusionURL:phusionURL];
			[phusionURL release];
			
			NSURL *phusionPassengerURL = [[NSURL alloc]
										  initWithString:@"http://modrails.com"];
			[sharedInstance setPhusionPassengerURL:phusionPassengerURL];
			[phusionPassengerURL release];
			
			NSWindow *aboutWindow = [sharedInstance window];
			
			NSImage *aboutBackgroundImage =
				[NSImage imageNamed:@"phusion_passenger_about"];
			
			NSColor *aboutBackgroundColor =
				[NSColor colorWithPatternImage:aboutBackgroundImage];
			
			[aboutBackgroundImage release];
			
			[aboutWindow setBackgroundColor:aboutBackgroundColor];
			
			[[sharedInstance versionLabel] setStringValue:@PASSENGER_VERSION];
		}
	}
	
	return sharedInstance;
}

-(IBAction)openPhusionURL:(id)sender {
	[[NSWorkspace sharedWorkspace] openURL: phusionURL];
}

-(IBAction)openPhusionPassengerURL:(id)sender {
	[[NSWorkspace sharedWorkspace] openURL: phusionPassengerURL];
}
@end
