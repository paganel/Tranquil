#import "TQRegularExpression.h"
#import "TQRuntime.h"
#import <objc/runtime.h>

@implementation TQRegularExpression
+ (NSRegularExpression *)tq_regularExpressionWithPattern:(NSString *)aPattern options:(NSRegularExpressionOptions)aOpts
{
    NSError *err = nil;
    NSRegularExpression *regex = [self regularExpressionWithPattern:aPattern options:aOpts error:&err];
    if(err)
        TQLog(@"%@", err);
    return regex;
}

- (id)matches:(NSString *)aString
{
    return [self numberOfMatchesInString:aString options:0 range:(NSRange){0, [aString length]}] > 0 ? TQValid : nil;
}

- (id)match:(NSString *)aString usingBlock:(id (^)(NSString *text, TQRange *range))aBlock
{
    [self enumerateMatchesInString:aString
                           options:0
                             range:(NSRange){0, [aString length]}
                        usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        NSRange r = match.range;
        aBlock([aString substringWithRange:r],
               [TQRange rangeWithLocation:[TQNumber numberWithInt:r.location] length:[TQNumber numberWithInt:r.length]]);
    }];
    return nil;
}
@end

@implementation NSString (TQRegularExpression)
- (id)matches:(TQRegularExpression *)aRegex
{
    return [aRegex matches:self];
}

- (id)match:(TQRegularExpression *)aRegex usingBlock:(id (^)(NSString *text, TQRange *range))aBlock
{
    return [aRegex match:self usingBlock:aBlock];
}
@end
