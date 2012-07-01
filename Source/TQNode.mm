#import "TQNode.h"

using namespace llvm;

NSString * const kTQSyntaxErrorDomain = @"org.tranquil.syntax";
NSString * const kTQGenericErrorDomain = @"org.tranquil.generic";

@implementation TQNode
+ (TQNode *)node
{
	return [[[self alloc] init] autorelease];
}

- (llvm::Value *)generateCodeInProgram:(TQProgram *)aProgram block:(TQNodeBlock *)aBlock error:(NSError **)aoErr
{
	NSLog(@"Code generation has not been implemented for %@.", [self class]);
	return NULL;
}
@end
