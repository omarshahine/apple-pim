#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for every failure reported by the shim.
extern NSString *const APRKShimErrorDomain;

/// A narrow bridge to Apple's private ReminderKit framework, for the Reminders metadata
/// EventKit cannot write: flags, subtasks, sections and tags.
///
/// ReminderKit is loaded with dlopen and every class is looked up by name, so nothing here
/// links against a private framework and the CLIs still build and run where it is missing.
/// Every selector is checked with respondsToSelector: before it is sent, and Objective-C
/// exceptions are converted to NSError. Each method performs exactly one save through
/// ReminderKit (the same path Reminders.app uses, so CloudKit sync is unchanged) and never
/// touches the Reminders database directly.
///
/// The shim does not decide whether a write is allowed or verify it. The Swift caller
/// checks PIMConfig and preconditions first and reads the store back afterwards.
@interface APRKShim : NSObject

/// Loads ReminderKit and checks the classes the shim needs. Safe to call repeatedly.
+ (BOOL)loadWithError:(NSError **)error;

/// Set or clear the reminder's flag.
+ (BOOL)setFlagged:(BOOL)flagged reminderID:(NSString *)reminderID error:(NSError **)error;

/// Create a subtask with `title` under `parentID`. Returns the new reminder's identifier.
+ (nullable NSString *)addSubtaskWithTitle:(NSString *)title parentID:(NSString *)parentID error:(NSError **)error;

/// Make `reminderID` a subtask of `parentID`, or a top-level reminder when `parentID` is nil.
+ (BOOL)moveReminderID:(NSString *)reminderID parentID:(nullable NSString *)parentID error:(NSError **)error;

/// Put the reminder into the section `sectionID` of its own list.
+ (BOOL)assignReminderID:(NSString *)reminderID sectionID:(NSString *)sectionID error:(NSError **)error;

/// Replace the reminder's tags with exactly `tags`.
+ (BOOL)replaceTags:(NSArray<NSString *> *)tags reminderID:(NSString *)reminderID error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
