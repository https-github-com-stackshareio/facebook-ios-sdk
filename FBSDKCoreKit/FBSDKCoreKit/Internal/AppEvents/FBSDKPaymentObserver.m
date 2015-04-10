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

#import "FBSDKPaymentObserver.h"

#import <StoreKit/StoreKit.h>

#import "FBSDKAppEvents+Internal.h"
#import "FBSDKDynamicFrameworkLoader.h"
#import "FBSDKLogger.h"
#import "FBSDKSettings.h"

static NSString *const FBSDKAppEventParameterImplicitlyLoggedPurchase    = @"_implicitlyLoggedPurchaseEvent";
static NSString *const FBSDKAppEventNamePurchaseFailed = @"fb_mobile_purchase_failed";
static NSString *const FBSDKAppEventParameterNameProductTitle = @"fb_content_title";
static NSString *const FBSDKAppEventParameterNameTransactionID = @"fb_transaction_id";
static int const FBSDKMaxParameterValueLength = 100;
static NSMutableArray *g_pendingRequestors;

@interface FBSDKPaymentProductRequestor : NSObject<SKProductsRequestDelegate>

@property (nonatomic, retain) SKPaymentTransaction *transaction;

- (instancetype)initWithTransaction:(SKPaymentTransaction*)transaction;
- (void)resolveProducts;

@end

@interface FBSDKPaymentObserver() <SKPaymentTransactionObserver>
@end

@implementation FBSDKPaymentObserver
{
  BOOL _observingTransactions;
}

+ (void)startObservingTransactions
{
  [[self singleton] startObservingTransactions];
}

+ (void)stopObservingTransactions
{
  [[self singleton] stopObservingTransactions];
}

//
// Internal methods
//

+ (FBSDKPaymentObserver *)singleton
{
  static dispatch_once_t pred;
  static FBSDKPaymentObserver *shared = nil;

  dispatch_once(&pred, ^{
    shared = [[FBSDKPaymentObserver alloc] init];
  });
  return shared;
}

- (instancetype) init
{
  self = [super init];
  if (self) {
    _observingTransactions = NO;
  }
  return self;
}

- (void)startObservingTransactions
{
  @synchronized (self) {
    if (!_observingTransactions) {
      [(SKPaymentQueue *)[fbsdkdfl_SKPaymentQueueClass() defaultQueue] addTransactionObserver:self];
      _observingTransactions = YES;
    }
  }
}

- (void)stopObservingTransactions
{
  @synchronized (self) {
    if (_observingTransactions) {
      [(SKPaymentQueue *)[fbsdkdfl_SKPaymentQueueClass() defaultQueue] removeTransactionObserver:self];
      _observingTransactions = NO;
    }
  }
}

- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray *)transactions
{
  for (SKPaymentTransaction *transaction in transactions) {
    switch (transaction.transactionState) {
      case SKPaymentTransactionStatePurchasing:
      case SKPaymentTransactionStatePurchased:
      case SKPaymentTransactionStateFailed:
        [self handleTransaction:transaction];
        break;
      case SKPaymentTransactionStateDeferred:
      case SKPaymentTransactionStateRestored:
        break;
    }
  }
}

- (void)handleTransaction:(SKPaymentTransaction *)transaction
{
  FBSDKPaymentProductRequestor *productRequest = [[FBSDKPaymentProductRequestor alloc] initWithTransaction:transaction];
  [productRequest resolveProducts];
}

@end

@interface FBSDKPaymentProductRequestor()
@property (nonatomic, retain) SKProductsRequest *productRequest;
@end

@implementation FBSDKPaymentProductRequestor

+ (void)initialize
{
  if ([self class] == [FBSDKPaymentProductRequestor class]) {
    g_pendingRequestors = [[NSMutableArray alloc] init];
  }
}

- (instancetype)initWithTransaction:(SKPaymentTransaction*)transaction
{
  self = [super init];
  if (self) {
    _transaction = transaction;
  }
  return self;
}

- (void)setProductRequest:(SKProductsRequest *)productRequest
{
  if (productRequest != _productRequest) {
    if (_productRequest) {
      _productRequest.delegate = nil;
    }
    _productRequest = productRequest;
  }
}

- (void)resolveProducts
{
  NSString *productId = self.transaction.payment.productIdentifier;
  NSSet *productIdentifiers = [NSSet setWithObjects:productId, nil];
  self.productRequest = [[fbsdkdfl_SKProductsRequestClass() alloc] initWithProductIdentifiers:productIdentifiers];
  self.productRequest.delegate = self;
  @synchronized(g_pendingRequestors) {
    [g_pendingRequestors addObject:self];
  }
  [self.productRequest start];
}

- (NSString *)getTruncatedString:(NSString *)inputString
{
  if (!inputString) {
    return @"";
  }

  return [inputString length] <= FBSDKMaxParameterValueLength ? inputString : [inputString substringToIndex:FBSDKMaxParameterValueLength];
}

- (void)logTransactionEvent:(SKProduct *)product
{
  NSString *eventName = nil;
  NSString *transactionID = nil;
  switch (self.transaction.transactionState) {
    case SKPaymentTransactionStatePurchasing:
      eventName = FBSDKAppEventNameInitiatedCheckout;
      break;
    case SKPaymentTransactionStatePurchased:
      eventName = FBSDKAppEventNamePurchased;
      transactionID = self.transaction.transactionIdentifier;
      break;
    case SKPaymentTransactionStateFailed:
      eventName = FBSDKAppEventNamePurchaseFailed;
      break;
    case SKPaymentTransactionStateDeferred:
    case SKPaymentTransactionStateRestored:
      return;
  }
  if (!eventName) {
    [FBSDKLogger singleShotLogEntry:FBSDKLoggingBehaviorAppEvents
                       formatString:@"FBSDKPaymentObserver logTransactionEvent: event name cannot be nil"];
    return;
  }

  SKPayment *payment = self.transaction.payment;
  NSMutableDictionary *eventParameters = [NSMutableDictionary dictionaryWithDictionary: @{
    FBSDKAppEventParameterNameContentID: payment.productIdentifier ?: @"",
    FBSDKAppEventParameterNameNumItems: @(payment.quantity),
  }];
  double totalAmount = 0;
  if (product) {
    totalAmount = payment.quantity * product.price.doubleValue;
    [eventParameters addEntriesFromDictionary: @{
      FBSDKAppEventParameterNameCurrency: [product.priceLocale objectForKey:NSLocaleCurrencyCode],
      FBSDKAppEventParameterNameNumItems: @(payment.quantity),
      FBSDKAppEventParameterNameProductTitle: [self getTruncatedString:product.localizedTitle],
      FBSDKAppEventParameterNameDescription: [self getTruncatedString:product.localizedDescription],
    }];
    if (transactionID) {
      [eventParameters setObject:transactionID forKey:FBSDKAppEventParameterNameTransactionID];
    }
  }

  [self logImplicitPurchaseEvent:eventName
                      valueToSum:@(totalAmount)
                      parameters:eventParameters];
}

- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response
{
  NSArray* products = response.products;
  NSArray* invalidProductIdentifiers = response.invalidProductIdentifiers;
  if (products.count + invalidProductIdentifiers.count != 1) {
    [FBSDKLogger singleShotLogEntry:FBSDKLoggingBehaviorAppEvents
                       formatString:@"FBSDKPaymentObserver: Expect to resolve one product per request"];
  }
  SKProduct *product = nil;
  if (products.count) {
    product = products[0];
  }
  [self logTransactionEvent:product];
}

- (void)requestDidFinish:(SKRequest *)request
{
  [self cleanUp];
}

- (void)request:(SKRequest *)request didFailWithError:(NSError *)error
{
  [self logTransactionEvent:nil];
  [self cleanUp];
}

- (void)cleanUp
{
  @synchronized(g_pendingRequestors) {
    [g_pendingRequestors removeObject:self];
  }
}

- (void)logImplicitPurchaseEvent:(NSString *)eventName
                      valueToSum:(NSNumber *)valueToSum
                      parameters:(NSDictionary *)parameters {
  NSMutableDictionary *eventParameters = [NSMutableDictionary dictionaryWithDictionary:parameters];
  [eventParameters setObject:@"1" forKey:FBSDKAppEventParameterImplicitlyLoggedPurchase];
  [FBSDKAppEvents logImplicitEvent:eventName
                        valueToSum:valueToSum
                        parameters:parameters
                       accessToken:nil];

  // Unless the behavior is set to only allow explicit flushing, we go ahead and flush, since purchase events
  // are relatively rare and relatively high value and worth getting across on wire right away.
  if ([FBSDKAppEvents flushBehavior] != FBSDKAppEventsFlushBehaviorExplicitOnly) {
    [[FBSDKAppEvents singleton] flushForReason:FBSDKAppEventsFlushReasonEagerlyFlushingEvent];
  }
}

@end