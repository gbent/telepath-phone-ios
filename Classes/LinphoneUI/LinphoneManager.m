/* LinphoneManager.h
 *
 * Copyright (C) 2011  Belledonne Comunications, Grenoble, France
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or   
 *  (at your option) any later version.                                 
 *                                                                      
 *  This program is distributed in the hope that it will be useful,     
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of      
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the       
 *  GNU Library General Public License for more details.                
 *                                                                      
 *  You should have received a copy of the GNU General Public License   
 *  along with this program; if not, write to the Free Software         
 *  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 */              


#import "LinphoneManager.h"
#include "linphonecore_utils.h"
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#import <AVFoundation/AVAudioSession.h>
#import <AudioToolbox/AudioToolbox.h>
#import "FastAddressBook.h"
#include "tunnel/TunnelManager.hh"
#import <AddressBook/AddressBook.h>


using namespace belledonnecomm;

static LinphoneCore* theLinphoneCore=nil;
static LinphoneManager* theLinphoneManager=nil;
static TunnelManager* sTunnelMgr=NULL;

extern "C" void libmsilbc_init();
#ifdef HAVE_AMR
extern void libmsamr_init();
#endif
@implementation LinphoneManager
@synthesize callDelegate;
@synthesize registrationDelegate;
@synthesize connectivity;

-(id) init {
    if ((self= [super init])) {
        mFastAddressBook = [[FastAddressBook alloc] init];
    }
    return self;
}
+(LinphoneManager*) instance {
	if (theLinphoneManager==nil) {
		theLinphoneManager = [[LinphoneManager alloc] init];
	}
	return theLinphoneManager;
}

-(NSString*) appendCountryCodeIfPossible:(NSString*) number {
    if (![number hasPrefix:@"+"] && ![number hasPrefix:@"00"]) {
        NSString* lCountryCode = [[NSUserDefaults standardUserDefaults] stringForKey:@"countrycode_preference"];
        if (lCountryCode && [lCountryCode length]>0) {
            //append country code
            return [lCountryCode stringByAppendingString:number];
        }
    }
    return number;
}

-(NSString*) getDisplayNameFromAddressBook:(NSString*) number andUpdateCallLog:(LinphoneCallLog*)log {
    //1 normalize
    NSString* lNormalizedNumber = [FastAddressBook normalizePhoneNumber:number];
    Contact* lContact = [mFastAddressBook getMatchingRecord:lNormalizedNumber];
    if (lContact) {
        CFStringRef lDisplayName = ABRecordCopyCompositeName(lContact.record);
        
        if (log) {
            //add phone type
            char ltmpString[256];
            CFStringRef lFormatedString = CFStringCreateWithFormat(NULL,NULL,CFSTR("phone_type:%@;"),lContact.numberType);
            CFStringGetCString(lFormatedString, ltmpString,sizeof(ltmpString), kCFStringEncodingUTF8);
            linphone_call_log_set_ref_key(log, ltmpString);
            CFRelease(lFormatedString);
        }
        return (NSString*)lDisplayName;    
    }
    //[number release];
 
    return nil;
}
-(void) updateCallWithAddressBookData:(LinphoneCall*) call {
    //1 copy adress book
    LinphoneCallLog* lLog = linphone_call_get_call_log(call);
    LinphoneAddress* lAddress;
    if (lLog->dir == LinphoneCallIncoming) {
        lAddress=lLog->from;
    } else {
        lAddress=lLog->to;
    }
    const char* lUserName = linphone_address_get_username(lAddress); 
    if (!lUserName) {
        //just return
        return;
    }
    
    NSString* lE164Number = [[NSString alloc] initWithCString:lUserName encoding:[NSString defaultCStringEncoding]];
    NSString* lDisplayName = [self getDisplayNameFromAddressBook:lE164Number andUpdateCallLog:lLog];
    
    if(lDisplayName) {        
        linphone_address_set_display_name(lAddress, [lDisplayName cStringUsingEncoding:[NSString defaultCStringEncoding]]);
    } else {
        ms_message("No contact entry found for  [%s] in address book",lUserName);
    }
    return;
}
-(void) onCall:(LinphoneCall*) currentCall StateChanged: (LinphoneCallState) new_state withMessage: (const char *)  message {
    const char* lUserNameChars=linphone_address_get_username(linphone_call_get_remote_address(currentCall));
    NSString* lUserName = lUserNameChars?[[NSString alloc] initWithCString:lUserNameChars]:NSLocalizedString(@"Unknown",nil);
    if (new_state == LinphoneCallIncomingReceived) {
       [self updateCallWithAddressBookData:currentCall]; // display name is updated 
    }
    const char* lDisplayNameChars =  linphone_address_get_display_name(linphone_call_get_remote_address(currentCall));        
	NSString* lDisplayName = lDisplayNameChars?[[NSString alloc] initWithCString:lDisplayNameChars]:@"";
	
	switch (new_state) {
			
		case LinphoneCallIncomingReceived: 
			[callDelegate	displayIncomingCallNotigicationFromUI:mCurrentViewController
														forUser:lUserName 
												withDisplayName:lDisplayName];
			break;
			
		case LinphoneCallOutgoingInit: 
			[callDelegate		displayCallInProgressFromUI:mCurrentViewController
											   forUser:lUserName 
									   withDisplayName:lDisplayName];
			break;
			
		case LinphoneCallConnected:
			[callDelegate	displayIncallFromUI:mCurrentViewController
									  forUser:lUserName 
							  withDisplayName:lDisplayName];
			break;
			
		case LinphoneCallError: { 
			/*
			 NSString* lTitle= state->message!=nil?[NSString stringWithCString:state->message length:strlen(state->message)]: @"Error";
			 NSString* lMessage=lTitle;
			 */
			NSString* lMessage;
			NSString* lTitle;
			LinphoneProxyConfig* proxyCfg;	
			//get default proxy
			linphone_core_get_default_proxy([LinphoneManager getLc],&proxyCfg);
			if (proxyCfg == nil) {
				lMessage=NSLocalizedString(@"Please make sure your device is connected to the internet and double check your SIP account configuration in the settings.",nil);
			} else {
				lMessage=[NSString stringWithFormat : NSLocalizedString(@"Cannot call %@",nil),lUserName];

			}
			
			if (message!=nil){
				lMessage=[NSString stringWithFormat : NSLocalizedString(@"%@\nReason was: %s",nil),lMessage, message];
			}
			lTitle=NSLocalizedString(@"Call failed",nil);
			
			UIAlertView* error = [[UIAlertView alloc] initWithTitle:lTitle
															message:lMessage 
														   delegate:nil 
												  cancelButtonTitle:NSLocalizedString(@"Dismiss",nil) 
												  otherButtonTitles:nil];
			[error show];
			[callDelegate	displayDialerFromUI:mCurrentViewController
									  forUser:@"" 
							  withDisplayName:@""];
			break;
		}
		case LinphoneCallEnd: 
			[callDelegate	displayDialerFromUI:mCurrentViewController
									  forUser:@"" 
							  withDisplayName:@""];
			break;
		default:
			break;
	}
	
}

+(LinphoneCore*) getLc {
	if (theLinphoneCore==nil) {
		@throw([NSException exceptionWithName:@"LinphoneCoreException" reason:@"Linphone core not initialized yet" userInfo:nil]);
	}
	return theLinphoneCore;
}

-(void) addLog:(NSString*) log {
	[mLogView addLog:log];
}
-(void)displayStatus:(NSString*) message {
	[callDelegate displayStatus:message];
}
//generic log handler for debug version
static void linphone_iphone_log_handler(int lev, const char *fmt, va_list args){
	NSString* format = [[NSString alloc] initWithCString:fmt encoding:[NSString defaultCStringEncoding]];
	NSLogv(format,args);
	NSString* formatedString = [[NSString alloc] initWithFormat:format arguments:args];
	[[LinphoneManager instance] addLog:formatedString];
	[format release];
	[formatedString release];
}

//Error/warning log handler 
static void linphone_iphone_log(struct _LinphoneCore * lc, const char * message) {
	NSString* log = [NSString stringWithCString:message encoding:[NSString defaultCStringEncoding]]; 
	NSLog(log,NULL);
	[[LinphoneManager instance]addLog:log];
}
//status 
static void linphone_iphone_display_status(struct _LinphoneCore * lc, const char * message) {
	[(LinphoneManager*)linphone_core_get_user_data(lc)  displayStatus:[[NSString alloc] initWithCString:message encoding:[NSString defaultCStringEncoding]]];
}

static void linphone_iphone_call_state(LinphoneCore *lc, LinphoneCall* call, LinphoneCallState state,const char* message) {
	/*LinphoneCallIdle,
	 LinphoneCallIncomingReceived,
	 LinphoneCallOutgoingInit,
	 LinphoneCallOutgoingProgress,
	 LinphoneCallOutgoingRinging,
	 LinphoneCallOutgoingEarlyMedia,
	 LinphoneCallConnected,
	 LinphoneCallStreamsRunning,
	 LinphoneCallPausing,
	 LinphoneCallPaused,
	 LinphoneCallResuming,
	 LinphoneCallRefered,
	 LinphoneCallError,
	 LinphoneCallEnd,
	 LinphoneCallPausedByRemote
	 */
	[(LinphoneManager*)linphone_core_get_user_data(lc) onCall:call StateChanged: state withMessage:  message];
	
	
	
}

-(void) onRegister:(LinphoneCore *)lc cfg:(LinphoneProxyConfig*) cfg state:(LinphoneRegistrationState) state message:(const char*) message {
	LinphoneAddress* lAddress = linphone_address_new(linphone_proxy_config_get_identity(cfg));
	NSString* lUserName = linphone_address_get_username(lAddress)? [[NSString alloc] initWithCString:linphone_address_get_username(lAddress) ]:@"";
	NSString* lDisplayName = linphone_address_get_display_name(lAddress)? [[NSString alloc] initWithCString:linphone_address_get_display_name(lAddress) ]:@"";
	NSString* lDomain = [[NSString alloc] initWithCString:linphone_address_get_domain(lAddress)];
	linphone_address_destroy(lAddress);
	
	if (state == LinphoneRegistrationOk) {
		[[(LinphoneManager*)linphone_core_get_user_data(lc) registrationDelegate] displayRegisteredFromUI:nil
											  forUser:lUserName
									  withDisplayName:lDisplayName
											 onDomain:lDomain ];
	} else if (state == LinphoneRegistrationProgress) {
		[registrationDelegate displayRegisteringFromUI:mCurrentViewController
											  forUser:lUserName
									  withDisplayName:lDisplayName
											 onDomain:lDomain ];
		
	} else if (state == LinphoneRegistrationCleared || state == LinphoneRegistrationNone) {
		[registrationDelegate displayNotRegisteredFromUI:mCurrentViewController];
	} else 	if (state == LinphoneRegistrationFailed ) {
		NSString* lErrorMessage=nil;
		if (linphone_proxy_config_get_error(cfg) == LinphoneReasonBadCredentials) {
			lErrorMessage = NSLocalizedString(@"Bad credentials, check your account settings",nil);
		} else if (linphone_proxy_config_get_error(cfg) == LinphoneReasonNoResponse) {
			lErrorMessage = NSLocalizedString(@"SIP server unreachable",nil);
		} 
		[registrationDelegate displayRegistrationFailedFromUI:mCurrentViewController
											   forUser:lUserName
									   withDisplayName:lDisplayName
											  onDomain:lDomain
												forReason:lErrorMessage];
		
		if (lErrorMessage != nil 
			&& registrationDelegate==nil
			&& linphone_proxy_config_get_error(cfg) != LinphoneReasonNoResponse) { //do not report network connection issue on registration
			//default behavior if no registration delegates
			
			UIAlertView* error = [[UIAlertView alloc]	initWithTitle:NSLocalizedString(@"Registration failure",nil)
															message:lErrorMessage
														   delegate:nil 
												  cancelButtonTitle:NSLocalizedString(@"Continue",nil) 
												  otherButtonTitles:nil ,nil];
			[error show];
		}
		
	}
	
}
static void linphone_iphone_registration_state(LinphoneCore *lc, LinphoneProxyConfig* cfg, LinphoneRegistrationState state,const char* message) {
	[(LinphoneManager*)linphone_core_get_user_data(lc) onRegister:lc cfg:cfg state:state message:message];
}

static LinphoneCoreVTable linphonec_vtable; 

-(void) configurePayloadType:(const char*) type fromPrefKey: (NSString*)key withRate:(int)rate  {
	if ([[NSUserDefaults standardUserDefaults] boolForKey:key]) { 		
		PayloadType* pt;
		if((pt = linphone_core_find_payload_type(theLinphoneCore,type,rate))) {
			linphone_core_enable_payload_type(theLinphoneCore,pt, TRUE);
		}
	} 
}
-(void) kickOffNetworkConnection {
	/*start a new thread to avoid blocking the main ui in case of peer host failure*/
	[NSThread detachNewThreadSelector:@selector(runNetworkConnection) toTarget:self withObject:nil];
}
-(void) runNetworkConnection {
	CFWriteStreamRef writeStream;
	CFStreamCreatePairWithSocketToHost(NULL, (CFStringRef)@"192.168.0.200"/*"linphone.org"*/, 15000, nil, &writeStream);
	CFWriteStreamOpen (writeStream);
	const char* buff="hello";
	CFWriteStreamWrite (writeStream,(const UInt8*)buff,strlen(buff));
	CFWriteStreamClose (writeStream);
}	

void networkReachabilityCallBack(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void * info) {
	ms_message("Network connection flag [%x]",flags);
	LinphoneManager* lLinphoneMgr = (LinphoneManager*)info;
	if ([LinphoneManager getLc] != nil) {
		if ((flags == 0) | (flags & (kSCNetworkReachabilityFlagsConnectionRequired |kSCNetworkReachabilityFlagsConnectionOnTraffic))) {
			[[LinphoneManager instance] kickOffNetworkConnection];
			linphone_core_set_network_reachable([LinphoneManager getLc],false);
			((LinphoneManager*)info).connectivity = none;
		} else {
			Connectivity  newConnectivity = flags & kSCNetworkReachabilityFlagsIsWWAN ? wwan:wifi;
			if (lLinphoneMgr.connectivity == none) {
				linphone_core_set_network_reachable([LinphoneManager getLc],true);
			} else if (lLinphoneMgr.connectivity != newConnectivity) {
				// connectivity has changed
				linphone_core_set_network_reachable([LinphoneManager getLc],false);
				linphone_core_set_network_reachable([LinphoneManager getLc],true);
			}
			lLinphoneMgr.connectivity=newConnectivity;
			ms_message("new network connectivity  of type [%s]",(newConnectivity==wifi?"wifi":"wwan"));
		}
		
	}
}

-(void) doLinphoneConfiguration:(NSNotification *)notification {
	ms_message("Configuring Linphone");
	if (theLinphoneCore==nil) {
		ms_warning("cannot configure linphone beacause not initialized yet");
		return;
	}
	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"debugenable_preference"]) {
		//redirect all traces to the iphone log framework
		linphone_core_enable_logs_with_cb((OrtpLogFunc)linphone_iphone_log_handler);
	}
	else {
		linphone_core_disable_logs();
	}
	NSString* transport = [[NSUserDefaults standardUserDefaults] stringForKey:@"transport_preference"];
	

	
	LCSipTransports transportValue;
	if (transport!=nil) {
		if (linphone_core_get_sip_transports(theLinphoneCore, &transportValue)) {
			ms_error("cannot get current transport");	
		}
		if ([transport isEqualToString:@"tcp"]) {
			if (transportValue.tcp_port == 0) transportValue.tcp_port=transportValue.udp_port;
			transportValue.udp_port=0;
		} else if ([transport isEqualToString:@"udp"]){
			if (transportValue.udp_port == 0) transportValue.udp_port=transportValue.tcp_port;
			transportValue.tcp_port=0;
		} else {
			ms_error("unexpected trasnport [%s]",[transport cStringUsingEncoding:[NSString defaultCStringEncoding]]);
		}
		if (linphone_core_set_sip_transports(theLinphoneCore, &transportValue)) {
			ms_error("cannot set transport");	
		}
	}
	
	
	
	
	// Set audio assets
	NSBundle* myBundle = [NSBundle mainBundle];
	const char*  lRing = [[myBundle pathForResource:@"oldphone-mono"ofType:@"wav"] cStringUsingEncoding:[NSString defaultCStringEncoding]];
	linphone_core_set_ring(theLinphoneCore, lRing );
	const char*  lRingBack = [[myBundle pathForResource:@"ringback"ofType:@"wav"] cStringUsingEncoding:[NSString defaultCStringEncoding]];
	linphone_core_set_ringback(theLinphoneCore, lRingBack);
 	
	
	
	
	//configure sip account
	
	//madatory parameters
	
	NSString* username = [[NSUserDefaults standardUserDefaults] stringForKey:@"username_preference"];
	NSString* domain = [[NSUserDefaults standardUserDefaults] stringForKey:@"domain_preference"];
	NSString* accountPassword = [[NSUserDefaults standardUserDefaults] stringForKey:@"password_preference"];
	bool configCheckDisable = [[NSUserDefaults standardUserDefaults] boolForKey:@"check_config_disable_preference"];
	bool isOutboundProxy= [[NSUserDefaults standardUserDefaults] boolForKey:@"outbound_proxy_preference"];
	
	
	//clear auth info list
	linphone_core_clear_all_auth_info(theLinphoneCore);
	//clear existing proxy config
	linphone_core_clear_proxy_config(theLinphoneCore);
	if (username && [username length] >0 && domain && [domain length]>0) {
		
		
		const char* identity = [[NSString stringWithFormat:@"sip:%@@%@",username,domain] cStringUsingEncoding:[NSString defaultCStringEncoding]];
		const char* password = [accountPassword cStringUsingEncoding:[NSString defaultCStringEncoding]];
		
		NSString* proxyAddress = [[NSUserDefaults standardUserDefaults] stringForKey:@"proxy_preference"];
		if ((!proxyAddress | [proxyAddress length] <1 ) && domain) {
			proxyAddress = [NSString stringWithFormat:@"sip:%@",domain] ;
		} else {
			proxyAddress = [NSString stringWithFormat:@"sip:%@",proxyAddress] ;
		}
		
		const char* proxy = [proxyAddress cStringUsingEncoding:[NSString defaultCStringEncoding]];
		
		NSString* prefix = [[NSUserDefaults standardUserDefaults] stringForKey:@"prefix_preference"];
        bool substitute_plus_by_00 = [[NSUserDefaults standardUserDefaults] boolForKey:@"substitute_+_by_00_preference"];
		//possible valid config detected
		LinphoneProxyConfig* proxyCfg;	
		proxyCfg = linphone_proxy_config_new();
		
		// add username password
		LinphoneAddress *from = linphone_address_new(identity);
		LinphoneAuthInfo *info;
		if (from !=0){
			info=linphone_auth_info_new(linphone_address_get_username(from),NULL,password,NULL,NULL);
			linphone_core_add_auth_info(theLinphoneCore,info);
		}
		linphone_address_destroy(from);
		
		// configure proxy entries
		linphone_proxy_config_set_identity(proxyCfg,identity);
		linphone_proxy_config_set_server_addr(proxyCfg,proxy);
		linphone_proxy_config_enable_register(proxyCfg,true);
		linphone_proxy_config_expires(proxyCfg, 600);
		
		if (isOutboundProxy)
			linphone_proxy_config_set_route(proxyCfg,proxy);
		
		if ([prefix length]>0) {
			linphone_proxy_config_set_dial_prefix(proxyCfg, [prefix cStringUsingEncoding:[NSString defaultCStringEncoding]]);
		}
		linphone_proxy_config_set_dial_escape_plus(proxyCfg,substitute_plus_by_00);
		
		linphone_core_add_proxy_config(theLinphoneCore,proxyCfg);
		//set to default proxy
		linphone_core_set_default_proxy(theLinphoneCore,proxyCfg);
		
	} else {
		if (configCheckDisable == false ) {
			UIAlertView* error = [[UIAlertView alloc]	initWithTitle:NSLocalizedString(@"Warning",nil)
															message:NSLocalizedString(@"It seems you have not configured any proxy server from settings",nil) 
														   delegate:self
												  cancelButtonTitle:NSLocalizedString(@"Continue",nil)
												  otherButtonTitles:NSLocalizedString(@"Never remind",nil),nil];
			[error show];
		}
	}		
	//tunnel
	BOOL lTunnelPrefEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"tunnel_enabled_preference"];
	NSString* lTunnelPrefAddress = [[NSUserDefaults standardUserDefaults] stringForKey:@"tunnel_address_preference"];
	NSString* lTunnelPrefPort = [[NSUserDefaults standardUserDefaults] stringForKey:@"tunnel_port_preference"];
	int lTunnelPort = 443;
	if (lTunnelPrefPort && [lTunnelPrefPort length] > 0  && [lTunnelPrefPort intValue]) {
		lTunnelPort = [lTunnelPrefPort intValue];
	}
	if (lTunnelPrefAddress && [lTunnelPrefAddress length]) {
		sTunnelMgr->cleanServers();
		sTunnelMgr->addServer([lTunnelPrefAddress cStringUsingEncoding:[NSString defaultCStringEncoding]],lTunnelPort);
	}
	sTunnelMgr->enable(lTunnelPrefEnabled);
	
	
	//Configure Codecs
	
	PayloadType *pt;
	//get codecs from linphonerc	
	const MSList *audioCodecs=linphone_core_get_audio_codecs(theLinphoneCore);
	const MSList *elem;
	//disable all codecs
	for (elem=audioCodecs;elem!=NULL;elem=elem->next){
		pt=(PayloadType*)elem->data;
		linphone_core_enable_payload_type(theLinphoneCore,pt,FALSE);
	}
	
	//read codecs from setting  bundle and enable them one by one
	[self configurePayloadType:"speex" fromPrefKey:@"speex_16k_preference" withRate:16000];
	[self configurePayloadType:"speex" fromPrefKey:@"speex_8k_preference" withRate:8000];
    [self configurePayloadType:"AMR" fromPrefKey:@"amr_8k_preference" withRate:8000];
	[self configurePayloadType:"GSM" fromPrefKey:@"gsm_8k_preference" withRate:8000];
	[self configurePayloadType:"iLBC" fromPrefKey:@"ilbc_preference" withRate:8000];
	[self configurePayloadType:"PCMU" fromPrefKey:@"pcmu_preference" withRate:8000];
	[self configurePayloadType:"PCMA" fromPrefKey:@"pcma_preference" withRate:8000];
	
	UIDevice* device = [UIDevice currentDevice];
	bool backgroundSupported = false;
	if ([device respondsToSelector:@selector(isMultitaskingSupported)])
		backgroundSupported = [device isMultitaskingSupported];
	
	if (backgroundSupported) {
		isbackgroundModeEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"backgroundmode_preference"];
	} else {
		isbackgroundModeEnabled=false;
	}
	
}
// no proxy configured alert 
- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
	if (buttonIndex == 1) {
		[[NSUserDefaults standardUserDefaults] setBool:true forKey:@"check_config_disable_preference"];
	}
}
-(void) destroyLibLinphone {
	[mIterateTimer invalidate];
	if (theLinphoneCore != nil) { //just in case application terminate before linphone core initialization
		linphone_core_destroy(theLinphoneCore);
		theLinphoneCore = nil;
        SCNetworkReachabilityUnscheduleFromRunLoop(proxyReachability, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        CFRelease(proxyReachability);
        proxyReachability=nil;
 	}
	if (sTunnelMgr) {
		delete sTunnelMgr;
		sTunnelMgr=NULL;
	}
}

//**********************BG mode management*************************///////////
-(void) enterBackgroundMode {
	
	struct addrinfo hints;
	struct addrinfo *res=NULL;
	int err;
	
	LinphoneProxyConfig* proxyCfg;
	LinphoneAddress *addr;
	linphone_core_get_default_proxy(theLinphoneCore, &proxyCfg);	
	linphone_core_stop_dtmf_stream(theLinphoneCore);
	
	if (isbackgroundModeEnabled && proxyCfg) {
		//For registration register
		linphone_core_refresh_registers(theLinphoneCore);
		
		
		//wait for registration answer
		int i=0;
		while (!linphone_proxy_config_is_registered(proxyCfg) && i++<40 ) {
			linphone_core_iterate(theLinphoneCore);
			usleep(100000);
		}
		//register keepalive
		if ([[UIApplication sharedApplication] setKeepAliveTimeout:600/*(NSTimeInterval)linphone_proxy_config_get_expires(proxyCfg)*/ 
														   handler:^{
															   ms_warning("keepalive handler");
															   if (theLinphoneCore == nil) {
																   ms_warning("It seam that Linphone BG mode was deacticated, just skipping");
																   return;
															   }
															   //kick up network cnx, just in case
															   [self kickOffNetworkConnection];
															   linphone_core_refresh_registers(theLinphoneCore);
															   linphone_core_iterate(theLinphoneCore);
														   }
			 ]) {
			
			
			ms_warning("keepalive handler succesfully registered"); 
		} else {
			ms_warning("keepalive handler cannot be registered");
		}
		LCSipTransports transportValue;
		if (linphone_core_get_sip_transports(theLinphoneCore, &transportValue)) {
			ms_error("cannot get current transport");	
		}
		
		if (mReadStream == nil && transportValue.udp_port>0) { //only for udp
			int sipsock = linphone_core_get_sip_socket(theLinphoneCore);	
			//disable keepalive handler
			linphone_core_enable_keep_alive(theLinphoneCore, false);
			const char *port;
			addr=linphone_address_new(linphone_proxy_config_get_addr(proxyCfg));
			memset(&hints,0,sizeof(hints));
			hints.ai_family=linphone_core_ipv6_enabled(theLinphoneCore) ? AF_INET6 : AF_INET;
			port=linphone_address_get_port(addr);
			if (port==NULL) port="5060";
			err=getaddrinfo(linphone_address_get_domain(addr),port,&hints,&res);
			if (err!=0){
				ms_error("getaddrinfo() failed for %s: %s",linphone_address_get_domain(addr),gai_strerror(err));
				linphone_address_destroy(addr);
				return;
			}
			err=connect(sipsock,res->ai_addr,res->ai_addrlen);
			if (err==-1){
				ms_error("Connect failed: %s",strerror(errno));
			}
			freeaddrinfo(res);
			
			CFStreamCreatePairWithSocket(NULL, (CFSocketNativeHandle)sipsock, &mReadStream,nil);
			
			if (!CFReadStreamSetProperty(mReadStream, kCFStreamNetworkServiceType, kCFStreamNetworkServiceTypeVoIP)) {
				ms_error("cannot set service type to voip for read stream");
			}
			
			
			if (!CFReadStreamOpen(mReadStream)) {
				ms_error("cannot open read stream");
			}		
		}
	}
	else {
		ms_warning("Entering lite bg mode");
		[self destroyLibLinphone];
	}
	
}


//scheduling loop
-(void) iterate {
	linphone_core_iterate(theLinphoneCore);
}


/*************
 *lib linphone init method
 */
-(void)startLibLinphone  {
	
	//get default config from bundle
	NSBundle* myBundle = [NSBundle mainBundle];
	NSString* factoryConfig = [myBundle pathForResource:@"linphonerc"ofType:nil] ;
	NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	NSString *confiFileName = [[paths objectAtIndex:0] stringByAppendingString:@"/.linphonerc"];
	connectivity=none;
	
	
	//log management	
	
	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"debugenable_preference"]) {
		//redirect all traces to the iphone log framework
		linphone_core_enable_logs_with_cb((OrtpLogFunc)linphone_iphone_log_handler);
	}
	else {
		linphone_core_disable_logs();
	}
	
	libmsilbc_init();
	
#ifdef HAVE_AMR
    libmsamr_init(); //load amr plugin if present from the liblinphone sdk
#endif	/*
	 * Initialize linphone core
	 */
	
	linphonec_vtable.show =NULL;
	linphonec_vtable.call_state_changed =(LinphoneCallStateCb)linphone_iphone_call_state;
	linphonec_vtable.registration_state_changed = linphone_iphone_registration_state;
	linphonec_vtable.notify_recv = NULL;
	linphonec_vtable.new_subscription_request = NULL;
	linphonec_vtable.auth_info_requested = NULL;
	linphonec_vtable.display_status = linphone_iphone_display_status;
	linphonec_vtable.display_message=linphone_iphone_log;
	linphonec_vtable.display_warning=linphone_iphone_log;
	linphonec_vtable.display_url=NULL;
	linphonec_vtable.text_received=NULL;
	linphonec_vtable.dtmf_received=NULL;
	
	theLinphoneCore = linphone_core_new (&linphonec_vtable
										 , [confiFileName cStringUsingEncoding:[NSString defaultCStringEncoding]]
										 , [factoryConfig cStringUsingEncoding:[NSString defaultCStringEncoding]]
										 ,self);
	sTunnelMgr = LinphoneCoreExtensionFactory::instance()->createTunnelManager(theLinphoneCore);
	sTunnelMgr->enableLogs(linphone_iphone_log_handler);
	
	[[NSUserDefaults standardUserDefaults] synchronize];//sync before loading config 
	
    
    proxyReachability=SCNetworkReachabilityCreateWithName(nil, "linphone.org");		
    proxyReachabilityContext.info=self;
	//initial state is network off should be done as soon as possible
	SCNetworkReachabilityFlags flags;
	SCNetworkReachabilityGetFlags(proxyReachability, &flags);
	networkReachabilityCallBack(proxyReachability,flags,self);	

	SCNetworkReachabilitySetCallback(proxyReachability, (SCNetworkReachabilityCallBack)networkReachabilityCallBack,&proxyReachabilityContext);
	SCNetworkReachabilityScheduleWithRunLoop(proxyReachability, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
	
	[self doLinphoneConfiguration:nil];
	[[NSNotificationCenter defaultCenter]	addObserver:self
											 selector:@selector(doLinphoneConfiguration:)
												 name:NSUserDefaultsDidChangeNotification object:nil];
	
	// start scheduler
	mIterateTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 
													 target:self 
												   selector:@selector(iterate) 
												   userInfo:nil 
													repeats:YES];
	//init audio session
	AVAudioSession *audioSession = [AVAudioSession sharedInstance];
	BOOL bAudioInputAvailable= [audioSession inputIsAvailable];
	
	if(!bAudioInputAvailable){
		UIAlertView* error = [[UIAlertView alloc]	initWithTitle:NSLocalizedString(@"No microphone",nil)
														message:NSLocalizedString(@"You need to plug a microphone to your device to use this application.",nil) 
													   delegate:nil 
											  cancelButtonTitle:NSLocalizedString(@"Ok",nil) 
											  otherButtonTitles:nil ,nil];
		[error show];
	}
	if ([[UIDevice currentDevice] respondsToSelector:@selector(isMultitaskingSupported)] 
		&& [UIApplication sharedApplication].applicationState ==  UIApplicationStateBackground) {
		//go directly to bg mode
		[self enterBackgroundMode];
	}

	
}
-(void) becomeActive {
    
    if (theLinphoneCore == nil) {
		//back from standby and background mode is disabled
		[self	startLibLinphone];
	} else {
        ms_message("becomming active, make sure we are registered");
		linphone_core_refresh_registers(theLinphoneCore);//just to make sure REGISTRATION is up to date
		
	}
	/*IOS specific*/
	linphone_core_start_dtmf_stream(theLinphoneCore);
    
	LCSipTransports transportValue;
	if (linphone_core_get_sip_transports(theLinphoneCore, &transportValue)) {
		ms_error("cannot get current transport");	
	}
	if (transportValue.udp_port != 0) {
		//enable sip keepalive 
		linphone_core_enable_keep_alive(theLinphoneCore, true);
	}
	if (mReadStream !=nil) {
		//unconnect
		int socket = linphone_core_get_sip_socket(theLinphoneCore);
		struct sockaddr hints;
		memset(&hints,0,sizeof(hints));
		hints.sa_family=AF_UNSPEC;
		connect(socket,&hints,sizeof(hints));
		CFReadStreamClose(mReadStream);
		CFRelease(mReadStream);
		mReadStream=nil;
	}
}
-(void) registerLogView:(id<LogView>) view {
	mLogView = view;
}

@end
