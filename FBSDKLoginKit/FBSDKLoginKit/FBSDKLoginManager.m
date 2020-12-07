// Copyright (c) 2014-present, Facebook, Inc. All rights reserved.
//
// You are hereby granted a non-exclusive, worldwide, royalty-free license to use,
// copy, modify, and distribute this software in source code or binary form for use
// in connection with the web services and APIs provided by Facebook.
//
// As with any software that integrates with the Facebook platform, your use of
// this software is subject to the Facebook Developer Principles and Policies
// [http://developers.facebook.com/policy/]. This copyright notice shall be
// included in all copies or substantial portions of the software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#import "TargetConditionals.h"

#if !TARGET_OS_TV

 #import "FBSDKLoginManager+Internal.h"

 #import "FBSDKLoginManagerLoginResult+Internal.h"

 #ifdef SWIFT_PACKAGE
  #import "FBSDKAccessToken.h"
  #import "FBSDKSettings.h"
 #else
  #import <FBSDKCoreKit/FBSDKCoreKit.h>
 #endif

 #ifdef FBSDKCOCOAPODS
  #import <FBSDKCoreKit/FBSDKCoreKit+Internal.h>
 #else
  #import "FBSDKCoreKit+Internal.h"
 #endif

 #import "FBSDKLoginCompletion.h"
 #import "FBSDKLoginConstants.h"
 #import "FBSDKLoginError.h"
 #import "FBSDKLoginManagerLogger.h"
 #import "FBSDKLoginUtility.h"
 #import "_FBSDKLoginRecoveryAttempter.h"

static int const FBClientStateChallengeLength = 20;
static NSString *const FBSDKExpectedChallengeKey = @"expected_login_challenge";
static NSString *const FBSDKExpectedNonceKey = @"expected_login_nonce";
static NSString *const FBSDKOauthPath = @"/dialog/oauth";
static NSString *const SFVCCanceledLogin = @"com.apple.SafariServices.Authentication";
static NSString *const ASCanceledLogin = @"com.apple.AuthenticationServices.WebAuthenticationSession";

// constants
FBSDKLoginAuthType FBSDKLoginAuthTypeRerequest = @"rerequest";
FBSDKLoginAuthType FBSDKLoginAuthTypeReauthorize = @"reauthorize";

@implementation FBSDKLoginManager
{
  FBSDKLoginManagerLoginResultBlock _handler;
  FBSDKLoginManagerLogger *_logger;
  FBSDKLoginManagerState _state;
  FBSDKKeychainStore *_keychainStore;
  FBSDKLoginConfiguration *_configuration;
  BOOL _usedSFAuthSession;
}

+ (void)initialize
{
  if (self == [FBSDKLoginManager class]) {
    [_FBSDKLoginRecoveryAttempter class];
    [FBSDKServerConfigurationManager loadServerConfigurationWithCompletionBlock:NULL];
  }
}

- (instancetype)init
{
  self = [super init];
  if (self) {
    self.authType = FBSDKLoginAuthTypeRerequest;
    NSString *keyChainServiceIdentifier = [NSString stringWithFormat:@"com.facebook.sdk.loginmanager.%@", [NSBundle mainBundle].bundleIdentifier];
    _keychainStore = [[FBSDKKeychainStore alloc] initWithService:keyChainServiceIdentifier accessGroup:nil];
  }
  return self;
}

- (void)logInFromViewController:(UIViewController *)viewController
                  configuration:(FBSDKLoginConfiguration *)configuration
                     completion:(FBSDKLoginManagerLoginResultBlock)completion
{
  if (![self validateLoginStartState]) {
    return;
  }
  self.fromViewController = viewController;
  _configuration = configuration;

  [self logInWithPermissions:configuration.requestedPermissions handler:completion];
}

- (void)logInWithPermissions:(NSArray<NSString *> *)permissions
          fromViewController:(UIViewController *)viewController
                     handler:(FBSDKLoginManagerLoginResultBlock)handler
{
  FBSDKLoginConfiguration *config = [[FBSDKLoginConfiguration alloc] initWithPermissions:permissions
                                                                     betaLoginExperience:FBSDKBetaLoginExperienceEnabled];
  [self logInFromViewController:viewController
                  configuration:config
                     completion:handler];
}

- (void)reauthorizeDataAccess:(UIViewController *)fromViewController handler:(FBSDKLoginManagerLoginResultBlock)handler
{
  if (![self validateLoginStartState]) {
    return;
  }
  self.fromViewController = fromViewController;
  [self reauthorizeDataAccess:handler];
}

- (void)logOut
{
  [FBSDKAccessToken setCurrentAccessToken:nil];
  [FBSDKAuthenticationToken setCurrentAuthenticationToken:nil];
  [FBSDKProfile setCurrentProfile:nil];
}

 #pragma mark - Private

- (void)raiseLoginException:(NSException *)exception
{
  _state = FBSDKLoginManagerStateIdle;
  [exception raise];
}

- (void)handleImplicitCancelOfLogIn
{
  FBSDKLoginManagerLoginResult *result = [[FBSDKLoginManagerLoginResult alloc] initWithToken:nil
                                                                                 isCancelled:YES
                                                                          grantedPermissions:NSSet.set
                                                                         declinedPermissions:NSSet.set];
  [result addLoggingExtra:@YES forKey:@"implicit_cancel"];
  [self invokeHandler:result error:nil];
}

- (BOOL)validateLoginStartState
{
  switch (_state) {
    case FBSDKLoginManagerStateStart: {
      if (self->_usedSFAuthSession) {
        // Using SFAuthenticationSession makes an interestitial dialog that blocks the app, but in certain situations such as
        // screen lock it can be dismissed and have the control returned to the app without invoking the completionHandler.
        // In this case, the viewcontroller has the control back and tried to reinvoke the login. This is acceptable behavior
        // and we should pop up the dialog again
        return YES;
      }

      NSString *errorStr = @"** WARNING: You are trying to start a login while a previous login has not finished yet."
      "This is unsupported behavior. You should wait until the previous login handler gets called to start a new login.";
      [FBSDKLogger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                         formatString:@"%@", errorStr];
      return NO;
    }
    case FBSDKLoginManagerStatePerformingLogin: {
      [self handleImplicitCancelOfLogIn];
      return YES;
    }
    case FBSDKLoginManagerStateIdle:
      _state = FBSDKLoginManagerStateStart;
      return YES;
  }
}

- (BOOL)isPerformingLogin
{
  return _state == FBSDKLoginManagerStatePerformingLogin;
}

- (void)assertPermissions:(NSArray *)permissions
{
  for (NSString *permission in permissions) {
    if (![permission isKindOfClass:[NSString class]]) {
      [self raiseLoginException:[NSException exceptionWithName:NSInvalidArgumentException
                                                        reason:@"Permissions must be string values."
                                                      userInfo:nil]];
    }
    if ([permission rangeOfString:@","].location != NSNotFound) {
      [self raiseLoginException:[NSException exceptionWithName:NSInvalidArgumentException
                                                        reason:@"Permissions should each be specified in separate string values in the array."
                                                      userInfo:nil]];
    }
  }
}

- (void)completeAuthentication:(FBSDKLoginCompletionParameters *)parameters expectChallenge:(BOOL)expectChallenge
{
  NSSet *recentlyGrantedPermissions = nil;
  NSSet *recentlyDeclinedPermissions = nil;
  FBSDKLoginManagerLoginResult *result = nil;
  NSError *error = parameters.error;

  NSString *tokenString = parameters.accessTokenString;
  BOOL cancelled = ((tokenString == nil) && (FBSDKAuthenticationToken.currentAuthenticationToken == nil));

  BOOL challengePassed = YES;
  if (expectChallenge) {
    // Perform this check early so we be sure to clear expected challenge in all cases.
    NSString *challengeReceived = parameters.challenge;
    NSString *challengeExpected = [[self loadExpectedChallenge] stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    if (![challengeExpected isEqualToString:challengeReceived]) {
      challengePassed = NO;
    }

    // Don't overwrite an existing error, if any.
    if (!error && !cancelled && !challengePassed) {
      error = [NSError fbErrorForFailedLoginWithCode:FBSDKLoginErrorBadChallengeString];
    }
  }

  [self storeExpectedChallenge:nil];

  if (!error) {
    if (!cancelled) {
      NSSet *grantedPermissions = parameters.permissions;
      NSSet *declinedPermissions = parameters.declinedPermissions;

      [self determineRecentlyGrantedPermissions:&recentlyGrantedPermissions
                    recentlyDeclinedPermissions:&recentlyDeclinedPermissions
                           forGrantedPermission:grantedPermissions
                            declinedPermissions:declinedPermissions];

      if (recentlyGrantedPermissions.count > 0) {
        FBSDKAccessToken *token = [[FBSDKAccessToken alloc] initWithTokenString:tokenString
                                                                    permissions:grantedPermissions.allObjects
                                                            declinedPermissions:declinedPermissions.allObjects
                                                             expiredPermissions:@[]
                                                                          appID:parameters.appID
                                                                         userID:parameters.userID
                                                                 expirationDate:parameters.expirationDate
                                                                    refreshDate:[NSDate date]
                                                       dataAccessExpirationDate:parameters.dataAccessExpirationDate
                                                                    graphDomain:parameters.graphDomain];
        result = [[FBSDKLoginManagerLoginResult alloc] initWithToken:token
                                                         isCancelled:NO
                                                  grantedPermissions:recentlyGrantedPermissions
                                                 declinedPermissions:recentlyDeclinedPermissions];

        if ([FBSDKAccessToken currentAccessToken]) {
          [self validateReauthentication:[FBSDKAccessToken currentAccessToken] withResult:result];
          // in a reauth, short circuit and let the login handler be called when the validation finishes.
          return;
        }
      }
    }

    if (cancelled || recentlyGrantedPermissions.count == 0) {
      NSSet *declinedPermissions = nil;
      if ([FBSDKAccessToken currentAccessToken] != nil) {
        // Always include the list of declined permissions from this login request
        // if an access token is already cached by the SDK
        declinedPermissions = recentlyDeclinedPermissions;
      }

      result = [[FBSDKLoginManagerLoginResult alloc] initWithToken:nil
                                                       isCancelled:cancelled
                                                grantedPermissions:NSSet.set
                                               declinedPermissions:declinedPermissions];
    }
  }

  if (result.token) {
    [FBSDKAccessToken setCurrentAccessToken:result.token];
  }

  [self invokeHandler:result error:error];
}

- (void)determineRecentlyGrantedPermissions:(NSSet **)recentlyGrantedPermissionsRef
                recentlyDeclinedPermissions:(NSSet **)recentlyDeclinedPermissionsRef
                       forGrantedPermission:(NSSet *)grantedPermissions
                        declinedPermissions:(NSSet *)declinedPermissions
{
  NSMutableSet *recentlyGrantedPermissions = [grantedPermissions mutableCopy];
  NSSet *previouslyGrantedPermissions = ([FBSDKAccessToken currentAccessToken]
    ? [FBSDKAccessToken currentAccessToken].permissions
    : nil);
  if (previouslyGrantedPermissions.count > 0) {
    // If there were no requested permissions for this auth - treat all permissions as granted.
    // Otherwise this is a reauth, so recentlyGranted should be a subset of what was requested.
    if (_requestedPermissions.count != 0) {
      [recentlyGrantedPermissions intersectSet:_requestedPermissions];
    }
  }

  NSMutableSet *recentlyDeclinedPermissions = [_requestedPermissions mutableCopy];
  [recentlyDeclinedPermissions intersectSet:declinedPermissions];

  if (recentlyGrantedPermissionsRef != NULL) {
    *recentlyGrantedPermissionsRef = [recentlyGrantedPermissions copy];
  }
  if (recentlyDeclinedPermissionsRef != NULL) {
    *recentlyDeclinedPermissionsRef = [recentlyDeclinedPermissions copy];
  }
}

- (void)invokeHandler:(FBSDKLoginManagerLoginResult *)result error:(NSError *)error
{
  [_logger endLoginWithResult:result error:error];
  [_logger endSession];
  _logger = nil;
  _state = FBSDKLoginManagerStateIdle;

  if (_handler) {
    FBSDKLoginManagerLoginResultBlock handler = _handler;
    _handler(result, error);
    if (handler == _handler) {
      _handler = nil;
    } else {
      [FBSDKLogger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                         formatString:@"** WARNING: You are requesting permissions inside the completion block of an existing login."
       "This is unsupported behavior. You should request additional permissions only when they are needed, such as requesting for publish_actions"
       "when the user performs a sharing action."];
    }
  }
}

- (NSString *)loadExpectedChallenge
{
  return [_keychainStore stringForKey:FBSDKExpectedChallengeKey];
}

- (NSString *)loadExpectedNonce
{
  return [_keychainStore stringForKey:FBSDKExpectedNonceKey];
}

- (NSDictionary *)logInParametersWithConfiguration:(FBSDKLoginConfiguration *)configuration
                               serverConfiguration:(FBSDKServerConfiguration *)serverConfiguration
{
  [FBSDKInternalUtility validateURLSchemes];

  NSMutableDictionary *loginParams = [NSMutableDictionary dictionary];
  [FBSDKTypeUtility dictionary:loginParams setObject:[FBSDKSettings appID] forKey:@"client_id"];
  [FBSDKTypeUtility dictionary:loginParams setObject:@"fbconnect://success" forKey:@"redirect_uri"];
  [FBSDKTypeUtility dictionary:loginParams setObject:@"touch" forKey:@"display"];
  [FBSDKTypeUtility dictionary:loginParams setObject:@"ios" forKey:@"sdk"];
  [FBSDKTypeUtility dictionary:loginParams setObject:@"true" forKey:@"return_scopes"];
  loginParams[@"sdk_version"] = FBSDK_VERSION_STRING;
  [FBSDKTypeUtility dictionary:loginParams setObject:@([FBSDKInternalUtility isFacebookAppInstalled]) forKey:@"fbapp_pres"];
  [FBSDKTypeUtility dictionary:loginParams setObject:self.authType forKey:@"auth_type"];
  [FBSDKTypeUtility dictionary:loginParams setObject:serverConfiguration.loggingToken forKey:@"logging_token"];
  long long cbtInMilliseconds = round(1000 * [NSDate date].timeIntervalSince1970);
  [FBSDKTypeUtility dictionary:loginParams setObject:@(cbtInMilliseconds) forKey:@"cbt"];
  [FBSDKTypeUtility dictionary:loginParams setObject:[FBSDKSettings isAutoLogAppEventsEnabled] ? @1 : @0 forKey:@"ies"];
  [FBSDKTypeUtility dictionary:loginParams setObject:[FBSDKSettings appURLSchemeSuffix] forKey:@"local_client_id"];
  [FBSDKTypeUtility dictionary:loginParams setObject:[FBSDKLoginUtility stringForAudience:self.defaultAudience] forKey:@"default_audience"];

  // TODO: Re-implement when server issue resolved - T80884847
  // [configuration.requestedPermissions setByAddingObject:@"openid"];
  NSSet *permissions = configuration.requestedPermissions;
  [FBSDKTypeUtility dictionary:loginParams setObject:[permissions.allObjects componentsJoinedByString:@","] forKey:@"scope"];

  NSString *expectedChallenge = [FBSDKLoginManager stringForChallenge];
  NSDictionary *state = @{@"challenge" : [FBSDKUtility URLEncode:expectedChallenge]};
  [FBSDKTypeUtility dictionary:loginParams setObject:[FBSDKBasicUtility JSONStringForObject:state error:NULL invalidObjectHandler:nil] forKey:@"state"];
  [self storeExpectedChallenge:expectedChallenge];

  NSString *responseType;
  if (configuration.betaLoginExperience == FBSDKBetaLoginExperienceRestricted) {
    responseType = @"id_token";
  } else {
    // TODO: Re-implement when server issue resolved - T80884847
    // responseType = @"id_token,token_or_nonce,signed_request,graph_domain";
    responseType = @"token_or_nonce,signed_request,graph_domain";
  }
  [FBSDKTypeUtility dictionary:loginParams setObject:responseType forKey:@"response_type"];

  [FBSDKTypeUtility dictionary:loginParams setObject:configuration.nonce forKey:@"nonce"];
  [self storeExpectedNonce:configuration.nonce keychainStore:_keychainStore];

  return loginParams;
}

- (void)logInWithPermissions:(NSSet *)permissions handler:(FBSDKLoginManagerLoginResultBlock)handler
{
  FBSDKServerConfiguration *serverConfiguration = [FBSDKServerConfigurationManager cachedServerConfiguration];
  _logger = [[FBSDKLoginManagerLogger alloc] initWithLoggingToken:serverConfiguration.loggingToken];

  _handler = [handler copy];
  _requestedPermissions = permissions;

  [_logger startSessionForLoginManager:self];

  [self logIn];
}

- (NSDictionary *)logInParametersFromURL:(NSURL *)url
{
  NSError *error = nil;
  FBSDKURL *parsedUrl = [FBSDKURL URLWithURL:url];
  NSDictionary *extras = parsedUrl.appLinkExtras;

  if (extras) {
    NSString *fbLoginDataString = extras[@"fb_login"];
    NSDictionary<id, id> *fbLoginData = [FBSDKTypeUtility dictionaryValue:[FBSDKBasicUtility objectForJSONString:fbLoginDataString error:&error]];
    if (!error && fbLoginData) {
      return fbLoginData;
    }
  }
  error = error ?: [FBSDKError errorWithCode:FBSDKLoginErrorUnknown message:@"Failed to parse deep link url for login data"];
  [self invokeHandler:nil error:error];
  return nil;
}

- (void)logInWithURL:(NSURL *)url
             handler:(nullable FBSDKLoginManagerLoginResultBlock)handler
{
  FBSDKServerConfiguration *serverConfiguration = [FBSDKServerConfigurationManager cachedServerConfiguration];
  _logger = [[FBSDKLoginManagerLogger alloc] initWithLoggingToken:serverConfiguration.loggingToken];
  _handler = [handler copy];

  [_logger startSessionForLoginManager:self];
  [_logger startAuthMethod:FBSDKLoginManagerLoggerAuthMethod_Applink];

  NSDictionary *params = [self logInParametersFromURL:url];
  if (params) {
    id<FBSDKLoginCompleting> completer = [[FBSDKLoginURLCompleter alloc] initWithURLParameters:params appID:[FBSDKSettings appID]];
    [completer completeLoginWithHandler:^(FBSDKLoginCompletionParameters *parameters) {
      [self completeAuthentication:parameters expectChallenge:NO];
    }];
  }
}

- (void)reauthorizeDataAccess:(FBSDKLoginManagerLoginResultBlock)handler
{
  FBSDKServerConfiguration *serverConfiguration = [FBSDKServerConfigurationManager cachedServerConfiguration];
  _logger = [[FBSDKLoginManagerLogger alloc] initWithLoggingToken:serverConfiguration.loggingToken];
  _handler = [handler copy];
  // Don't need to pass permissions for data reauthorization.
  _requestedPermissions = [NSSet set];
  _configuration = [FBSDKLoginConfiguration init];
  self.authType = FBSDKLoginAuthTypeReauthorize;
  [_logger startSessionForLoginManager:self];
  [self logIn];
}

- (void)logIn
{
  FBSDKServerConfiguration *serverConfiguration = [FBSDKServerConfigurationManager cachedServerConfiguration];
  NSDictionary *loginParams = [self logInParametersWithConfiguration:_configuration serverConfiguration:serverConfiguration];
  self->_usedSFAuthSession = NO;

  void (^completion)(BOOL, NSError *) = ^void (BOOL didPerformLogIn, NSError *error) {
    if (didPerformLogIn) {
      self->_state = FBSDKLoginManagerStatePerformingLogin;
    } else if ([error.domain isEqualToString:SFVCCanceledLogin]
               || [error.domain isEqualToString:ASCanceledLogin]) {
      [self handleImplicitCancelOfLogIn];
    } else {
      if (!error) {
        error = [NSError errorWithDomain:FBSDKLoginErrorDomain code:FBSDKLoginErrorUnknown userInfo:nil];
      }
      [self invokeHandler:nil error:error];
    }
  };

  [self performBrowserLogInWithParameters:loginParams handler:^(BOOL openedURL,
                                                                NSError *openedURLError) {
                                                                  completion(openedURL, openedURLError);
                                                                }];
}

- (void)storeExpectedChallenge:(NSString *)challengeExpected
{
  [_keychainStore setString:challengeExpected
                     forKey:FBSDKExpectedChallengeKey
              accessibility:[FBSDKDynamicFrameworkLoader loadkSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]];
}

- (void)storeExpectedNonce:(NSString *)nonceExpected keychainStore:(FBSDKKeychainStore *)keychainStore
{
  [keychainStore setString:nonceExpected
                    forKey:FBSDKExpectedNonceKey
             accessibility:[FBSDKDynamicFrameworkLoader loadkSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]];
}

+ (NSString *)stringForChallenge
{
  NSString *challenge = [FBSDKCrypto randomString:FBClientStateChallengeLength];

  return [challenge stringByReplacingOccurrencesOfString:@"+" withString:@"="];
}

- (void)validateReauthentication:(FBSDKAccessToken *)currentToken withResult:(FBSDKLoginManagerLoginResult *)loginResult
{
  FBSDKGraphRequest *requestMe = [[FBSDKGraphRequest alloc] initWithGraphPath:@"me"
                                                                   parameters:@{@"fields" : @""}
                                                                  tokenString:loginResult.token.tokenString
                                                                   HTTPMethod:nil
                                                                        flags:FBSDKGraphRequestFlagDoNotInvalidateTokenOnError | FBSDKGraphRequestFlagDisableErrorRecovery];
  [requestMe startWithCompletionHandler:^(FBSDKGraphRequestConnection *connection, id result, NSError *error) {
    NSString *actualID = result[@"id"];
    if ([currentToken.userID isEqualToString:actualID]) {
      [FBSDKAccessToken setCurrentAccessToken:loginResult.token];
      [self invokeHandler:loginResult error:nil];
    } else {
      NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
      [FBSDKTypeUtility dictionary:userInfo setObject:error forKey:NSUnderlyingErrorKey];
      NSError *resultError = [NSError errorWithDomain:FBSDKLoginErrorDomain
                                                 code:FBSDKLoginErrorUserMismatch
                                             userInfo:userInfo];
      [self invokeHandler:nil error:resultError];
    }
  }];
}

 #pragma mark - Test Methods

- (void)setHandler:(FBSDKLoginManagerLoginResultBlock)handler
{
  _handler = [handler copy];
}

- (void)setRequestedPermissions:(NSSet *)requestedPermissions
{
  _requestedPermissions = [requestedPermissions copy];
}

// change bool to auth method string.
- (void)performBrowserLogInWithParameters:(NSDictionary *)loginParams
                                  handler:(FBSDKBrowserLoginSuccessBlock)handler
{
  [_logger willAttemptAppSwitchingBehavior];

  FBSDKServerConfiguration *configuration = [FBSDKServerConfigurationManager cachedServerConfiguration];
  BOOL useSafariViewController = [configuration useSafariViewControllerForDialogName:FBSDKDialogConfigurationNameLogin];
  NSString *authMethod = (useSafariViewController ? FBSDKLoginManagerLoggerAuthMethod_SFVC : FBSDKLoginManagerLoggerAuthMethod_Browser);

  loginParams = [_logger parametersWithTimeStampAndClientState:loginParams forAuthMethod:authMethod];

  NSURL *authURL = nil;
  NSError *error;
  NSURL *redirectURL = [FBSDKInternalUtility appURLWithHost:@"authorize" path:@"" queryParameters:@{} error:&error];
  if (!error) {
    NSMutableDictionary *browserParams = [loginParams mutableCopy];
    [FBSDKTypeUtility dictionary:browserParams
                       setObject:redirectURL
                          forKey:@"redirect_uri"];
    authURL = [FBSDKInternalUtility facebookURLWithHostPrefix:@"m."
                                                         path:FBSDKOauthPath
                                              queryParameters:browserParams
                                                        error:&error];
  }

  [_logger startAuthMethod:authMethod];

  if (authURL) {
    void (^handlerWrapper)(BOOL, NSError *) = ^(BOOL didOpen, NSError *anError) {
      if (handler) {
        handler(didOpen, anError);
      }
    };

    if (useSafariViewController) {
      // Note based on above, authURL must be a http scheme. If that changes, add a guard, otherwise SFVC can throw
      self->_usedSFAuthSession = YES;
      [[FBSDKBridgeAPI sharedInstance] openURLWithSafariViewController:authURL
                                                                sender:self
                                                    fromViewController:self.fromViewController
                                                               handler:handlerWrapper];
    } else {
      [[FBSDKBridgeAPI sharedInstance] openURL:authURL sender:self handler:handlerWrapper];
    }
  } else {
    error = error ?: [FBSDKError errorWithCode:FBSDKLoginErrorUnknown message:@"Failed to construct oauth browser url"];
    if (handler) {
      handler(NO, error);
    }
  }
}

 #pragma mark - FBSDKURLOpening
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation
{
  BOOL isFacebookURL = [self canOpenURL:url forApplication:application sourceApplication:sourceApplication annotation:annotation];

  if (!isFacebookURL && [self isPerformingLogin]) {
    [self handleImplicitCancelOfLogIn];
  }

  if (isFacebookURL) {
    NSDictionary *urlParameters = [FBSDKLoginUtility queryParamsFromLoginURL:url];
    id<FBSDKLoginCompleting> completer = [[FBSDKLoginURLCompleter alloc] initWithURLParameters:urlParameters
                                                                                         appID:[FBSDKSettings appID]];

    if (_logger == nil) {
      _logger = [FBSDKLoginManagerLogger loggerFromParameters:urlParameters];
    }

    // any necessary strong reference is maintained by the FBSDKLoginURLCompleter handler
    [completer completeLoginWithHandler:^(FBSDKLoginCompletionParameters *parameters) {
                 [self completeAuthentication:parameters expectChallenge:YES];
               } nonce:[self loadExpectedNonce]];
  }

  return isFacebookURL;
}

- (BOOL) canOpenURL:(NSURL *)url
     forApplication:(UIApplication *)application
  sourceApplication:(NSString *)sourceApplication
         annotation:(id)annotation
{
  // verify the URL is intended as a callback for the SDK's log in
  return [url.scheme hasPrefix:[NSString stringWithFormat:@"fb%@", [FBSDKSettings appID]]]
  && [url.host isEqualToString:@"authorize"];
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
  if ([self isPerformingLogin]) {
    [self handleImplicitCancelOfLogIn];
  }
}

- (BOOL)isAuthenticationURL:(NSURL *)url
{
  return [url.path hasSuffix:FBSDKOauthPath];
}

- (BOOL)shouldStopPropagationOfURL:(NSURL *)url
{
  return
  [url.scheme hasPrefix:[NSString stringWithFormat:@"fb%@", [FBSDKSettings appID]]]
  && [url.host isEqualToString:@"no-op"];
}

@end

#endif
