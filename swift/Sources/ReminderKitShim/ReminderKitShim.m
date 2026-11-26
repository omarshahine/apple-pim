#import "ReminderKitShim.h"
#include <dlfcn.h>

// Selector and class shapes follow remctl (MIT, https://github.com/viticci/remctl), whose
// `remctl-private.m` exercises each of these paths against a live store on macOS 26 and a
// macOS 27 beta. Only those tested paths are used here.

NSString *const APRKShimErrorDomain = @"com.omarshahine.apple-pim.reminderkit";

static NSString *const kReminderKitPath = @"/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit";

// Informal declarations so the compiler knows each selector's signature. Classes are looked
// up with NSClassFromString, so none of these create a link-time reference.
@interface NSObject (APRKReminderKit)
+ (id)objectIDWithURL:(NSURL *)url;
- (NSUUID *)uuid;
- (id)initWithStore:(id)store;
- (id)fetchReminderWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchListSectionWithObjectID:(id)objectID error:(NSError **)error;
- (id)updateReminder:(id)reminder;
- (id)updateList:(id)list;
- (id)addReminderWithTitle:(NSString *)title toReminderSubtaskContextChangeItem:(id)context;
- (BOOL)saveSynchronouslyWithError:(NSError **)error;
- (id)remObjectID;
- (id)list;
- (BOOL)isSubtask;
- (id)flaggedContext;
- (void)setFlagged:(NSInteger)flagged;
- (id)hashtagContext;
- (id)addHashtagWithType:(NSInteger)type name:(NSString *)name;
- (void)removeAllHashtags;
- (id)subtaskContext;
- (void)addReminderChangeItem:(id)changeItem;
- (void)removeFromParentReminder;
- (id)sectionsContextChangeItem;
- (void)setUnsavedMembershipsOfRemindersInSections:(id)memberships;
- (id)initWithMemberIdentifier:(NSUUID *)memberIdentifier groupIdentifier:(NSUUID *)groupIdentifier isObsolete:(BOOL)isObsolete modifiedOn:(NSDate *)modifiedOn;
- (id)initWithMemberships:(NSArray *)memberships;
@end

static BOOL setError(NSError **error, NSInteger code, NSString *message) {
    if (error) {
        *error = [NSError errorWithDomain:APRKShimErrorDomain code:code
                                 userInfo:@{NSLocalizedDescriptionKey: message ?: @"ReminderKit error"}];
    }
    return NO;
}

static BOOL setUnderlying(NSError **error, NSString *prefix, NSError *underlying) {
    NSString *detail = underlying.localizedDescription ?: @"no detail";
    return setError(error, 2, [NSString stringWithFormat:@"%@: %@", prefix, detail]);
}

static BOOL responds(id target, SEL selector, NSError **error, NSString *what) {
    if (target && [target respondsToSelector:selector]) return YES;
    return setError(error, 3, [NSString stringWithFormat:
        @"ReminderKit on this macOS version does not support %@ (%@ is unavailable)",
        what, NSStringFromSelector(selector)]);
}

static NSURL *objectURL(NSString *entity, NSString *identifier) {
    return [NSURL URLWithString:[NSString stringWithFormat:@"x-apple-reminderkit://%@/%@", entity, identifier]];
}

static BOOL validIdentifier(NSString *identifier) {
    return [identifier isKindOfClass:[NSString class]] && [[NSUUID alloc] initWithUUIDString:identifier] != nil;
}

// Checked before any ReminderKit object is created, so malformed input never reaches remindd.
static BOOL requireIdentifiers(NSArray *identifiers, NSError **error) {
    for (id identifier in identifiers) {
        if (!validIdentifier(identifier)) {
            return setError(error, 4, [NSString stringWithFormat:@"Not a Reminders identifier: %@", identifier]);
        }
    }
    return YES;
}

@implementation APRKShim

+ (BOOL)loadWithError:(NSError **)error {
    static BOOL loaded = NO;
    static NSString *loadFailure = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!dlopen(kReminderKitPath.fileSystemRepresentation, RTLD_NOW)) {
            const char *reason = dlerror();
            loadFailure = [NSString stringWithFormat:@"Could not load ReminderKit: %s", reason ?: "unknown error"];
            return;
        }
        for (NSString *name in @[@"REMStore", @"REMSaveRequest", @"REMObjectID", @"REMMembership", @"REMMemberships"]) {
            if (!NSClassFromString(name)) {
                loadFailure = [NSString stringWithFormat:@"ReminderKit is missing %@ on this macOS version", name];
                return;
            }
        }
        loaded = YES;
    });
    if (!loaded) return setError(error, 1, loadFailure ?: @"ReminderKit unavailable");
    return YES;
}

+ (id)newStore {
    return [[NSClassFromString(@"REMStore") alloc] init];
}

+ (id)newSaveRequestWithStore:(id)store {
    return [[NSClassFromString(@"REMSaveRequest") alloc] initWithStore:store];
}

+ (id)fetchReminder:(NSString *)identifier store:(id)store error:(NSError **)error {
    if (!validIdentifier(identifier)) {
        setError(error, 4, [NSString stringWithFormat:@"Not a reminder identifier: %@", identifier]);
        return nil;
    }
    id objectID = [NSClassFromString(@"REMObjectID") objectIDWithURL:objectURL(@"REMCDReminder", identifier)];
    if (!objectID) {
        setError(error, 4, @"Could not build a ReminderKit object ID");
        return nil;
    }
    if (!responds(store, @selector(fetchReminderWithObjectID:error:), error, @"reminder fetches")) return nil;
    NSError *fetchError = nil;
    id reminder = [store fetchReminderWithObjectID:objectID error:&fetchError];
    if (!reminder) {
        setUnderlying(error, [NSString stringWithFormat:@"Reminder %@ not found in ReminderKit", identifier], fetchError);
        return nil;
    }
    return reminder;
}

+ (BOOL)save:(id)save what:(NSString *)what error:(NSError **)error {
    if (!responds(save, @selector(saveSynchronouslyWithError:), error, @"saving")) return NO;
    NSError *saveError = nil;
    if (![save saveSynchronouslyWithError:&saveError]) {
        return setUnderlying(error, [NSString stringWithFormat:@"ReminderKit %@ save failed", what], saveError);
    }
    return YES;
}

+ (BOOL)run:(NSString *)what error:(NSError **)error block:(BOOL (^)(NSError **))block {
    if (![self loadWithError:error]) return NO;
    @try {
        return block(error);
    } @catch (NSException *exception) {
        return setError(error, 5, [NSString stringWithFormat:@"ReminderKit %@ raised %@: %@",
                                   what, exception.name, exception.reason ?: @"no reason"]);
    }
}

+ (BOOL)setFlagged:(BOOL)flagged reminderID:(NSString *)reminderID error:(NSError **)error {
    return [self run:@"flag" error:error block:^BOOL(NSError **err) {
        if (!requireIdentifiers(@[reminderID ?: @""], err)) return NO;
        id store = [self newStore];
        id reminder = [self fetchReminder:reminderID store:store error:err];
        if (!reminder) return NO;
        id save = [self newSaveRequestWithStore:store];
        if (!responds(save, @selector(updateReminder:), err, @"reminder updates")) return NO;
        id change = [save updateReminder:reminder];
        if (!responds(change, @selector(flaggedContext), err, @"flags")) return NO;
        id context = [change flaggedContext];
        if (!responds(context, @selector(setFlagged:), err, @"flags")) return NO;
        [context setFlagged:flagged ? 1 : 0];
        return [self save:save what:@"flag" error:err];
    }];
}

+ (NSString *)addSubtaskWithTitle:(NSString *)title parentID:(NSString *)parentID error:(NSError **)error {
    __block NSString *created = nil;
    BOOL ok = [self run:@"subtask creation" error:error block:^BOOL(NSError **err) {
        if (![title isKindOfClass:[NSString class]] || title.length == 0) return setError(err, 4, @"A subtask title is required");
        if (!requireIdentifiers(@[parentID ?: @""], err)) return NO;
        id store = [self newStore];
        id parent = [self fetchReminder:parentID store:store error:err];
        if (!parent) return NO;
        if ([parent respondsToSelector:@selector(isSubtask)] && [parent isSubtask]) {
            return setError(err, 6, @"The parent is itself a subtask; Reminders allows one level of subtasks");
        }
        id save = [self newSaveRequestWithStore:store];
        if (!responds(save, @selector(updateReminder:), err, @"reminder updates")) return NO;
        id parentChange = [save updateReminder:parent];
        if (!responds(parentChange, @selector(subtaskContext), err, @"subtasks")) return NO;
        id context = [parentChange subtaskContext];
        if (!context) return setError(err, 3, @"ReminderKit gave the parent no subtask context");
        if (!responds(save, @selector(addReminderWithTitle:toReminderSubtaskContextChangeItem:), err, @"subtask creation")) return NO;
        id subtask = [save addReminderWithTitle:title toReminderSubtaskContextChangeItem:context];
        if (!subtask) return setError(err, 2, @"ReminderKit did not create the subtask");
        id objectID = [subtask respondsToSelector:@selector(remObjectID)] ? [subtask remObjectID] : nil;
        NSString *identifier = [objectID respondsToSelector:@selector(uuid)] ? [[objectID uuid] UUIDString] : nil;
        if (identifier.length == 0) return setError(err, 2, @"ReminderKit did not report the new subtask's identifier");
        if (![self save:save what:@"subtask creation" error:err]) return NO;
        created = identifier;
        return YES;
    }];
    return ok ? created : nil;
}

+ (BOOL)moveReminderID:(NSString *)reminderID parentID:(NSString *)parentID error:(NSError **)error {
    return [self run:@"subtask move" error:error block:^BOOL(NSError **err) {
        if (!requireIdentifiers(parentID ? @[reminderID ?: @"", parentID] : @[reminderID ?: @""], err)) return NO;
        id store = [self newStore];
        id reminder = [self fetchReminder:reminderID store:store error:err];
        if (!reminder) return NO;
        if (!responds(reminder, @selector(isSubtask), err, @"subtask moves")) return NO;
        id save = [self newSaveRequestWithStore:store];
        if (!responds(save, @selector(updateReminder:), err, @"reminder updates")) return NO;
        id moving = [save updateReminder:reminder];
        if (!moving) return setError(err, 2, @"Could not create a ReminderKit change item");

        if (parentID) {
            if ([parentID caseInsensitiveCompare:reminderID] == NSOrderedSame) {
                return setError(err, 6, @"A reminder cannot be its own parent");
            }
            id parent = [self fetchReminder:parentID store:store error:err];
            if (!parent) return NO;
            if ([parent isSubtask]) {
                return setError(err, 6, @"The parent is itself a subtask; Reminders allows one level of subtasks");
            }
            id parentChange = [save updateReminder:parent];
            if (!responds(parentChange, @selector(subtaskContext), err, @"subtasks")) return NO;
            id context = [parentChange subtaskContext];
            if (!responds(context, @selector(addReminderChangeItem:), err, @"subtask moves")) return NO;
            [context addReminderChangeItem:moving];
        } else {
            if (![reminder isSubtask]) return YES; // already top level: nothing to save
            if (!responds(reminder, @selector(list), err, @"subtask moves")) return NO;
            id list = [reminder list];
            if (!list) return setError(err, 2, @"The reminder has no list");
            if (!responds(save, @selector(updateList:), err, @"list updates")) return NO;
            id listChange = [save updateList:list];
            if (!responds(moving, @selector(removeFromParentReminder), err, @"removing a subtask from its parent")) return NO;
            if (!responds(listChange, @selector(addReminderChangeItem:), err, @"subtask moves")) return NO;
            [moving removeFromParentReminder];
            [listChange addReminderChangeItem:moving];
        }
        return [self save:save what:@"subtask move" error:err];
    }];
}

+ (BOOL)assignReminderID:(NSString *)reminderID sectionID:(NSString *)sectionID error:(NSError **)error {
    return [self run:@"section assignment" error:error block:^BOOL(NSError **err) {
        if (!requireIdentifiers(@[reminderID ?: @"", sectionID ?: @""], err)) return NO;
        id store = [self newStore];
        id reminder = [self fetchReminder:reminderID store:store error:err];
        if (!reminder) return NO;
        id sectionObjectID = [NSClassFromString(@"REMObjectID") objectIDWithURL:objectURL(@"REMCDListSection", sectionID)];
        if (!sectionObjectID) return setError(err, 4, @"Could not build a ReminderKit section ID");
        if (!responds(store, @selector(fetchListSectionWithObjectID:error:), err, @"sections")) return NO;
        NSError *fetchError = nil;
        id section = [store fetchListSectionWithObjectID:sectionObjectID error:&fetchError];
        if (!section) return setUnderlying(err, @"Section not found in ReminderKit", fetchError);
        if (!responds(reminder, @selector(list), err, @"sections")) return NO;
        id list = [reminder list];
        if (!list) return setError(err, 2, @"The reminder has no list");
        id save = [self newSaveRequestWithStore:store];
        if (!responds(save, @selector(updateList:), err, @"list updates")) return NO;
        id listChange = [save updateList:list];
        if (!responds(listChange, @selector(sectionsContextChangeItem), err, @"sections")) return NO;
        id context = [listChange sectionsContextChangeItem];
        if (!responds(context, @selector(setUnsavedMembershipsOfRemindersInSections:), err, @"section assignment")) return NO;
        id reminderObjectID = [reminder remObjectID];
        NSUUID *member = [reminderObjectID uuid];
        NSUUID *group = [sectionObjectID uuid];
        if (!member || !group) return setError(err, 2, @"Could not read ReminderKit identifiers");
        id membership = [[NSClassFromString(@"REMMembership") alloc] initWithMemberIdentifier:member
                                                                             groupIdentifier:group
                                                                                  isObsolete:NO
                                                                                  modifiedOn:[NSDate date]];
        id memberships = [[NSClassFromString(@"REMMemberships") alloc] initWithMemberships:@[membership]];
        if (!membership || !memberships) return setError(err, 2, @"Could not build a ReminderKit membership");
        [context setUnsavedMembershipsOfRemindersInSections:memberships];
        return [self save:save what:@"section assignment" error:err];
    }];
}

+ (BOOL)replaceTags:(NSArray<NSString *> *)tags reminderID:(NSString *)reminderID error:(NSError **)error {
    return [self run:@"tag update" error:error block:^BOOL(NSError **err) {
        if (!requireIdentifiers(@[reminderID ?: @""], err)) return NO;
        id store = [self newStore];
        id reminder = [self fetchReminder:reminderID store:store error:err];
        if (!reminder) return NO;
        id save = [self newSaveRequestWithStore:store];
        if (!responds(save, @selector(updateReminder:), err, @"reminder updates")) return NO;
        id change = [save updateReminder:reminder];
        if (!responds(change, @selector(hashtagContext), err, @"tags")) return NO;
        id context = [change hashtagContext];
        if (!responds(context, @selector(removeAllHashtags), err, @"tag replacement")) return NO;
        if (tags.count > 0 && !responds(context, @selector(addHashtagWithType:name:), err, @"adding tags")) return NO;
        [context removeAllHashtags];
        for (NSString *tag in tags) {
            // Type 1 is a user hashtag, as Reminders.app writes it.
            [context addHashtagWithType:1 name:tag];
        }
        return [self save:save what:@"tag update" error:err];
    }];
}

@end
