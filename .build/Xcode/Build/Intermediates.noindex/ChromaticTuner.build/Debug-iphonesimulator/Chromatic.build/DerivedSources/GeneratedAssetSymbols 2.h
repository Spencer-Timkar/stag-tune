#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The "StagBody" asset catalog image resource.
static NSString * const ACImageNameStagBody AC_SWIFT_PRIVATE = @"StagBody";

/// The "StagMandible" asset catalog image resource.
static NSString * const ACImageNameStagMandible AC_SWIFT_PRIVATE = @"StagMandible";

#undef AC_SWIFT_PRIVATE
