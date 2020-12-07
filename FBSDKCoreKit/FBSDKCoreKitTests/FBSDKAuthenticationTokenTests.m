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

#import <OCMock/OCMock.h>
#import <XCTest/XCTest.h>

#import <FBSDKCoreKit/FBSDKCoreKit.h>

#import "FBSDKCoreKit+Internal.h"
#import "FBSDKCoreKitTests-Swift.h"
#import "FBSDKTestCase.h"
#import "FBSDKTestCoder.h"

@interface FBSDKAuthenticationToken (Testing)

- (instancetype)initWithTokenString:(NSString *)tokenString
                              nonce:(NSString *)nonce
                             claims:(NSDictionary *)claims;

@end

@interface FBSDKAuthenticationTokenTests : FBSDKTestCase

@end

@implementation FBSDKAuthenticationTokenTests
{
  FBSDKAuthenticationToken *_token;
  NotificationCenterSpy *_notificationCenterSpy;
}

- (void)setUp
{
  [super setUp];

  _notificationCenterSpy = [NotificationCenterSpy new];
  [self stubDefaultNotificationCenterWith:_notificationCenterSpy];
}

// MARK: - Persistence

- (void)testRetrievingCurrentToken
{
  FakeTokenCache *cache = [[FakeTokenCache alloc] initWithAccessToken:nil authenticationToken:nil];
  _token = [[FBSDKAuthenticationToken alloc] initWithTokenString:@"" nonce:@"" claims:@[]];
  id partialTokenMock = OCMPartialMock(_token);
  OCMStub([partialTokenMock tokenCache]).andReturn(cache);

  FBSDKAuthenticationToken.currentAuthenticationToken = _token;
  XCTAssertEqualObjects(
    cache.authenticationToken,
    _token,
    "Setting the global authentication token should invoke the cache"
  );

  [partialTokenMock stopMocking];
  partialTokenMock = nil;
}

- (void)testEncoding
{
  NSString *expectedTokenString = @"expectedTokenString";
  NSString *expectedNonce = @"expectedNonce";

  FBSDKTestCoder *coder = [FBSDKTestCoder new];
  _token = [[FBSDKAuthenticationToken alloc] initWithTokenString:expectedTokenString
                                                           nonce:expectedNonce claims:@{}];
  [_token encodeWithCoder:coder];

  XCTAssertEqualObjects(
    coder.encodedObject[@"FBSDKAuthenticationTokenTokenStringCodingKey"],
    expectedTokenString,
    @"Should encode the expected token string"
  );
  XCTAssertEqualObjects(
    coder.encodedObject[@"FBSDKAuthenticationTokenNonceCodingKey"],
    expectedNonce,
    @"Should encode the expected nonce string"
  );
}

- (void)testDecodingEntryWithMethodName
{
  FBSDKTestCoder *coder = [FBSDKTestCoder new];
  _token = [[FBSDKAuthenticationToken alloc] initWithCoder:coder];

  XCTAssertEqualObjects(
    coder.decodedObject[@"FBSDKAuthenticationTokenTokenStringCodingKey"],
    [NSString class],
    @"Initializing from a decoder should attempt to decode a String for the token string key"
  );
  XCTAssertEqualObjects(
    coder.decodedObject[@"FBSDKAuthenticationTokenNonceCodingKey"],
    [NSString class],
    @"Initializing from a decoder should attempt to decode a String for the nonce key"
  );
}

// MARK: - Notifications

- (void)testPostsNotificationOnSettingInitial
{
  _token = [[FBSDKAuthenticationToken alloc] initWithTokenString:@"" nonce:@"" claims:@[]];;
  FBSDKAuthenticationToken.currentAuthenticationToken = _token;

  XCTAssertTrue(
    [_notificationCenterSpy.capturedPostNames containsObject:FBSDKAuthenticationTokenDidChangeNotification],
    "Should post a notification when the authentication token is initially set"
  );
  XCTAssertTrue(
    [_notificationCenterSpy.capturedPostObjects containsObject:FBSDKAuthenticationToken.class],
    "Notification should contain information about the object that posted it"
  );
  XCTAssertTrue(
    [_notificationCenterSpy.capturedPostUserInfos containsObject:@{
       FBSDKAuthenticationTokenChangeNewKey : _token
     }],
    "Notification should contain information about the change that occured"
  );
}

- (void)testPostsNotificationOnSettingNew
{
  _token = [[FBSDKAuthenticationToken alloc] initWithTokenString:@"" nonce:@"" claims:@[]];
  FBSDKAuthenticationToken *token2 = [[FBSDKAuthenticationToken alloc] initWithTokenString:@"" nonce:@"" claims:@[]];
  FBSDKAuthenticationToken.currentAuthenticationToken = _token;

  [_notificationCenterSpy clearTestEvidence];
  FBSDKAuthenticationToken.currentAuthenticationToken = token2;

  NSDictionary *expectedUserInfo = @{
    FBSDKAuthenticationTokenChangeOldKey : _token,
    FBSDKAuthenticationTokenChangeNewKey : token2
  };

  XCTAssertTrue(
    [_notificationCenterSpy.capturedPostNames containsObject:FBSDKAuthenticationTokenDidChangeNotification],
    "Should post a notification when the authentication token is changed"
  );
  XCTAssertTrue(
    [_notificationCenterSpy.capturedPostObjects containsObject:FBSDKAuthenticationToken.class],
    "Notification should contain information about the object that posted it"
  );
  XCTAssertTrue(
    [_notificationCenterSpy.capturedPostUserInfos containsObject:expectedUserInfo],
    "Notification should contain information about the change that occured"
  );
}

- (void)testPostsNotificationOnSettingNil
{
  _token = [[FBSDKAuthenticationToken alloc] initWithTokenString:@"" nonce:@"" claims:@[]];
  FBSDKAuthenticationToken.currentAuthenticationToken = _token;

  [_notificationCenterSpy clearTestEvidence];
  FBSDKAuthenticationToken.currentAuthenticationToken = nil;

  NSDictionary *expectedUserInfo = @{
    FBSDKAuthenticationTokenChangeOldKey : _token
  };

  XCTAssertTrue(
    [_notificationCenterSpy.capturedPostNames containsObject:FBSDKAuthenticationTokenDidChangeNotification],
    "Should post a notification when the authentication token is removed"
  );
  XCTAssertTrue(
    [_notificationCenterSpy.capturedPostObjects containsObject:FBSDKAuthenticationToken.class],
    "Notification should contain information about the object that posted it"
  );
  XCTAssertTrue(
    [_notificationCenterSpy.capturedPostUserInfos containsObject:expectedUserInfo],
    "Notification should contain information about the change that occured"
  );
}

@end
