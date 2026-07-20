import ArgumentParser
import Contacts
import Foundation
import PIMConfig
import Security

@main
struct ContactsCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contacts-cli",
        abstract: "Manage macOS Contacts",
        subcommands: [
            AuthStatus.self,
            ListContainers.self,
            ListGroups.self,
            ListContacts.self,
            SearchContacts.self,
            GetContact.self,
            CreateContact.self,
            UpdateContact.self,
            DeleteContact.self,
            ConfigCommand.self,
        ]
    )
}

// MARK: - Auth Status (no prompts)

struct AuthStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth-status",
        abstract: "Check contacts authorization status without triggering prompts"
    )

    func run() throws {
        let status: String
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: status = "authorized"
        case .denied: status = "denied"
        case .restricted: status = "restricted"
        case .notDetermined: status = "notDetermined"
        @unknown default: status = "unknown"
        }
        let result: [String: Any] = ["authorization": status]
        let data = try JSONSerialization.data(withJSONObject: result)
        print(String(data: data, encoding: .utf8)!)
    }
}

// MARK: - Shared Utilities

let contactStore = CNContactStore()

func requestContactsAccess() async throws {
    let status = CNContactStore.authorizationStatus(for: .contacts)

    switch status {
    case .authorized:
        return
    case .notDetermined:
        let granted = try await contactStore.requestAccess(for: .contacts)
        guard granted else {
            throw CLIError.accessDenied("Contacts access denied. Grant access in System Settings > Privacy & Security > Contacts")
        }
    case .denied, .restricted:
        throw CLIError.accessDenied("Contacts access denied. Grant access in System Settings > Privacy & Security > Contacts")
    @unknown default:
        throw CLIError.accessDenied("Unknown contacts authorization status")
    }
}

enum CLIError: Error, LocalizedError {
    case accessDenied(String)
    case notFound(String)
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied(let msg): return msg
        case .notFound(let msg): return msg
        case .invalidInput(let msg): return msg
        }
    }
}

// MARK: - PIMConfig Helpers

func checkContactsEnabled(config: PIMConfiguration) throws {
    guard config.contacts.enabled else {
        throw CLIError.accessDenied("Contacts access is disabled by PIM configuration")
    }
}

/// Parse a birthday string into DateComponents.
/// Accepts "YYYY-MM-DD" (with year) or "MM-DD" (without year).
func parseBirthday(_ string: String) throws -> DateComponents {
    let parts = string.split(separator: "-").compactMap { Int($0) }
    switch parts.count {
    case 3:
        // YYYY-MM-DD
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
    case 2:
        // MM-DD (no year)
        return DateComponents(month: parts[0], day: parts[1])
    default:
        throw CLIError.invalidInput("Invalid birthday format '\(string)'. Use YYYY-MM-DD or MM-DD.")
    }
}

/// Map a user-friendly label string to a CNLabel constant.
func labelConstant(_ label: String?) -> String {
    guard let label = label?.lowercased() else { return CNLabelOther }
    switch label {
    case "home": return CNLabelHome
    case "work": return CNLabelWork
    case "school": return CNLabelSchool
    case "other": return CNLabelOther
    case "main": return CNLabelPhoneNumberMain
    case "mobile": return CNLabelPhoneNumberMobile
    case "iphone": return CNLabelPhoneNumberiPhone
    case "home fax": return CNLabelPhoneNumberHomeFax
    case "work fax": return CNLabelPhoneNumberWorkFax
    case "pager": return CNLabelPhoneNumberPager
    case "homepage": return CNLabelURLAddressHomePage
    case "icloud": return CNLabelEmailiCloud
    case "anniversary": return CNLabelDateAnniversary
    default: return label
    }
}

/// Map a user-friendly relation label to a CNLabel constant.
func relationLabelConstant(_ label: String?) -> String {
    guard let label = label?.lowercased() else { return CNLabelOther }
    switch label {
    case "assistant": return CNLabelContactRelationAssistant
    case "manager": return CNLabelContactRelationManager
    case "colleague": return CNLabelContactRelationColleague
    case "teacher": return CNLabelContactRelationTeacher
    case "spouse": return CNLabelContactRelationSpouse
    case "partner": return CNLabelContactRelationPartner
    case "parent": return CNLabelContactRelationParent
    case "mother": return CNLabelContactRelationMother
    case "father": return CNLabelContactRelationFather
    case "child": return CNLabelContactRelationChild
    case "daughter": return CNLabelContactRelationDaughter
    case "son": return CNLabelContactRelationSon
    case "sibling": return CNLabelContactRelationSibling
    case "sister": return CNLabelContactRelationSister
    case "brother": return CNLabelContactRelationBrother
    case "friend": return CNLabelContactRelationFriend
    case "wife": return CNLabelContactRelationWife
    case "husband": return CNLabelContactRelationHusband
    default: return labelConstant(label)
    }
}

/// Parse a JSON string into an array of dictionaries.
func parseJSONArray(_ json: String) throws -> [[String: Any]] {
    guard let data = json.data(using: .utf8) else {
        throw CLIError.invalidInput("Invalid JSON array: \(json)")
    }

    let parsedAny: Any
    do {
        parsedAny = try JSONSerialization.jsonObject(with: data)
    } catch {
        throw CLIError.invalidInput("Invalid JSON array: \(json)")
    }

    guard let parsed = parsedAny as? [[String: Any]] else {
        throw CLIError.invalidInput("Invalid JSON array: \(json)")
    }
    return parsed
}

/// Parse JSON addresses into CNLabeledValue<CNPostalAddress> array.
func parseAddresses(_ json: String) throws -> [CNLabeledValue<CNPostalAddress>] {
    let items = try parseJSONArray(json)
    return items.map { item in
        let addr = CNMutablePostalAddress()
        addr.street = item["street"] as? String ?? ""
        addr.city = item["city"] as? String ?? ""
        addr.state = item["state"] as? String ?? ""
        addr.postalCode = item["postalCode"] as? String ?? ""
        addr.country = item["country"] as? String ?? ""
        addr.isoCountryCode = item["isoCountryCode"] as? String ?? ""
        addr.subLocality = item["subLocality"] as? String ?? ""
        addr.subAdministrativeArea = item["subAdministrativeArea"] as? String ?? ""
        return CNLabeledValue(label: labelConstant(item["label"] as? String), value: addr as CNPostalAddress)
    }
}

/// Parse JSON URLs into CNLabeledValue<NSString> array.
func parseURLs(_ json: String) throws -> [CNLabeledValue<NSString>] {
    let items = try parseJSONArray(json)
    return items.map { item in
        let value = item["value"] as? String ?? ""
        return CNLabeledValue(label: labelConstant(item["label"] as? String), value: value as NSString)
    }
}

/// Parse JSON social profiles into CNLabeledValue<CNSocialProfile> array.
func parseSocialProfiles(_ json: String) throws -> [CNLabeledValue<CNSocialProfile>] {
    let items = try parseJSONArray(json)
    return items.map { item in
        let profile = CNSocialProfile(
            urlString: item["url"] as? String ?? "",
            username: item["username"] as? String ?? "",
            userIdentifier: item["userIdentifier"] as? String ?? "",
            service: item["service"] as? String ?? ""
        )
        return CNLabeledValue(label: labelConstant(item["label"] as? String), value: profile)
    }
}

/// Parse JSON instant messages into CNLabeledValue<CNInstantMessageAddress> array.
func parseInstantMessages(_ json: String) throws -> [CNLabeledValue<CNInstantMessageAddress>] {
    let items = try parseJSONArray(json)
    return items.map { item in
        let im = CNInstantMessageAddress(
            username: item["username"] as? String ?? "",
            service: item["service"] as? String ?? ""
        )
        return CNLabeledValue(label: labelConstant(item["label"] as? String), value: im)
    }
}

/// Parse JSON relations into CNLabeledValue<CNContactRelation> array.
func parseRelations(_ json: String) throws -> [CNLabeledValue<CNContactRelation>] {
    let items = try parseJSONArray(json)
    return items.map { item in
        let name = item["name"] as? String ?? ""
        return CNLabeledValue(label: relationLabelConstant(item["label"] as? String), value: CNContactRelation(name: name))
    }
}

/// Parse JSON dates into CNLabeledValue<NSDateComponents> array.
func parseDates(_ json: String) throws -> [CNLabeledValue<NSDateComponents>] {
    let items = try parseJSONArray(json)
    return items.map { item in
        let comps = NSDateComponents()
        if let year = item["year"] as? Int { comps.year = year }
        if let month = item["month"] as? Int { comps.month = month }
        if let day = item["day"] as? Int { comps.day = day }
        return CNLabeledValue(label: labelConstant(item["label"] as? String), value: comps)
    }
}

/// Parse JSON emails into CNLabeledValue<NSString> array.
func parseEmails(_ json: String) throws -> [CNLabeledValue<NSString>] {
    let items = try parseJSONArray(json)
    return items.map { item in
        let value = item["value"] as? String ?? ""
        return CNLabeledValue(label: labelConstant(item["label"] as? String), value: value as NSString)
    }
}

/// Parse JSON phones into CNLabeledValue<CNPhoneNumber> array.
func parsePhones(_ json: String) throws -> [CNLabeledValue<CNPhoneNumber>] {
    let items = try parseJSONArray(json)
    return items.map { item in
        let value = item["value"] as? String ?? ""
        return CNLabeledValue(label: labelConstant(item["label"] as? String), value: CNPhoneNumber(stringValue: value))
    }
}

/// Build a replacement multivalue array that reuses the contact's existing
/// CNLabeledValue instances (and thus their stable identifiers) for entries
/// whose value is unchanged.
///
/// Wholesale replacement with freshly constructed CNLabeledValues forces the
/// store to delete and recreate every entry. On some cards (observed with
/// linked and/or iCloud-synced contacts) rewriting the pre-existing entries
/// fails deterministically with CoreData 134092 ("Unhandled error occurred
/// during faulting") — and a failed save can even partially apply, leaving
/// duplicated or dropped entries. Reusing identifiers keeps the save diff to
/// genuine adds/removes/label edits, matching how Contacts.app edits cards.
func mergeLabeledStrings(
    existing: [CNLabeledValue<NSString>],
    desired: [CNLabeledValue<NSString>]
) -> [CNLabeledValue<NSString>] {
    var pool = existing
    return desired.map { want in
        guard let idx = pool.firstIndex(where: {
            ($0.value as String).caseInsensitiveCompare(want.value as String) == .orderedSame
        }) else {
            return want
        }
        let found = pool.remove(at: idx)
        return found.label == want.label ? found : found.settingLabel(want.label)
    }
}

/// Phone-number variant of `mergeLabeledStrings` (see rationale there).
func mergeLabeledPhones(
    existing: [CNLabeledValue<CNPhoneNumber>],
    desired: [CNLabeledValue<CNPhoneNumber>]
) -> [CNLabeledValue<CNPhoneNumber>] {
    var pool = existing
    return desired.map { want in
        guard let idx = pool.firstIndex(where: { $0.value.stringValue == want.value.stringValue }) else {
            return want
        }
        let found = pool.remove(at: idx)
        return found.label == want.label ? found : found.settingLabel(want.label)
    }
}

func outputJSON(_ value: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
       let string = String(data: data, encoding: .utf8) {
        print(string)
    }
}

/// Check if an error (or any of its underlying errors) is a CoreData merge conflict (code 134092).
func isMergeConflict(_ error: Error) -> Bool {
    var current: NSError? = error as NSError
    while let err = current {
        if err.code == 134092 {
            return true
        }
        current = err.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
}

/// Fetch a single contact by identifier for mutation.
///
/// `unified: true` returns the unified contact (merged view across linked cards).
/// `unified: false` returns the raw source card, which is the only view that can be
/// saved reliably when the contact is linked: executing a CNSaveRequest against a
/// unified snapshot whose multivalue entries (emails/phones/addresses) belong to a
/// *different* linked card fails deterministically with CoreData 134092
/// ("Unhandled error occurred during faulting") and can even partially apply.
func fetchContactForMutation(id: String, unified: Bool) throws -> CNContact? {
    if unified {
        let predicate = CNContact.predicateForContacts(withIdentifiers: [id])
        return try contactStore.unifiedContacts(matching: predicate, keysToFetch: keysToFetch).first
    }
    let request = CNContactFetchRequest(keysToFetch: keysToFetch)
    request.predicate = CNContact.predicateForContacts(withIdentifiers: [id])
    request.unifyResults = false
    request.mutableObjects = false
    var fetched: CNContact?
    try contactStore.enumerateContacts(with: request) { c, stop in
        fetched = c
        stop.pointee = true
    }
    return fetched
}

/// Escape a string for embedding inside a double-quoted AppleScript literal.
func appleScriptEscaped(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

/// Run an AppleScript via /usr/bin/osascript. Throws CLIError on failure.
func runAppleScript(_ script: String) throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-"]
    let stdin = Pipe()
    let stderrPipe = Pipe()
    proc.standardInput = stdin
    proc.standardOutput = Pipe()
    proc.standardError = stderrPipe
    try proc.run()
    stdin.fileHandleForWriting.write(script.data(using: .utf8)!)
    stdin.fileHandleForWriting.closeFile()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 {
        let err = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        throw CLIError.accessDenied(
            "Contacts.app fallback failed (osascript exit \(proc.terminationStatus)): \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
        )
    }
}

/// Whether this process holds com.apple.developer.contacts.notes.
///
/// Since macOS 13, Contacts notes are gated behind that entitlement. Requesting
/// CNContactNoteKey without it does NOT merely yield empty notes: any
/// CNSaveRequest built from a contact fetched that way fails with CoreData
/// 134092 ("Unhandled error occurred during faulting") whenever the card
/// actually has a note, because the store tries to fault the unauthorized note
/// property while writing — and the failed save can partially apply. So the
/// note key must only be requested when the entitlement is present.
let hasNotesEntitlement: Bool = {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let value = SecTaskCopyValueForEntitlement(
        task, "com.apple.developer.contacts.notes" as CFString, nil
    )
    return (value as? Bool) == true
}()

let keysToFetch: [CNKeyDescriptor] = {
    var keys: [CNKeyDescriptor] = [
    CNContactIdentifierKey as CNKeyDescriptor,
    CNContactGivenNameKey as CNKeyDescriptor,
    CNContactFamilyNameKey as CNKeyDescriptor,
    CNContactMiddleNameKey as CNKeyDescriptor,
    CNContactNamePrefixKey as CNKeyDescriptor,
    CNContactNameSuffixKey as CNKeyDescriptor,
    CNContactNicknameKey as CNKeyDescriptor,
    CNContactOrganizationNameKey as CNKeyDescriptor,
    CNContactJobTitleKey as CNKeyDescriptor,
    CNContactDepartmentNameKey as CNKeyDescriptor,
    CNContactEmailAddressesKey as CNKeyDescriptor,
    CNContactPhoneNumbersKey as CNKeyDescriptor,
    CNContactPostalAddressesKey as CNKeyDescriptor,
    CNContactUrlAddressesKey as CNKeyDescriptor,
    CNContactBirthdayKey as CNKeyDescriptor,
    CNContactImageDataAvailableKey as CNKeyDescriptor,
    CNContactThumbnailImageDataKey as CNKeyDescriptor,
    CNContactImageDataKey as CNKeyDescriptor,
    CNContactTypeKey as CNKeyDescriptor,
    CNContactRelationsKey as CNKeyDescriptor,
    CNContactSocialProfilesKey as CNKeyDescriptor,
    CNContactInstantMessageAddressesKey as CNKeyDescriptor,
    CNContactPhoneticGivenNameKey as CNKeyDescriptor,
    CNContactPhoneticMiddleNameKey as CNKeyDescriptor,
    CNContactPhoneticFamilyNameKey as CNKeyDescriptor,
    CNContactPhoneticOrganizationNameKey as CNKeyDescriptor,
    CNContactPreviousFamilyNameKey as CNKeyDescriptor,
    CNContactNonGregorianBirthdayKey as CNKeyDescriptor,
    CNContactDatesKey as CNKeyDescriptor,
    CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
    ]
    if hasNotesEntitlement {
        keys.append(CNContactNoteKey as CNKeyDescriptor)
    }
    return keys
}()

func containerToDict(_ container: CNContainer) -> [String: Any] {
    let typeName: String
    switch container.type {
    case .local: typeName = "local"
    case .exchange: typeName = "exchange"
    case .cardDAV: typeName = "cardDAV"
    case .unassigned: typeName = "unassigned"
    @unknown default: typeName = "unknown"
    }
    return [
        "id": container.identifier,
        "name": container.name,
        "type": typeName
    ]
}

func groupToDict(_ group: CNGroup) -> [String: Any] {
    return [
        "id": group.identifier,
        "name": group.name
    ]
}

func contactToDict(_ contact: CNContact, brief: Bool = false) -> [String: Any] {
    var dict: [String: Any] = [
        "id": contact.identifier,
        "givenName": contact.givenName,
        "familyName": contact.familyName,
        "fullName": CNContactFormatter.string(from: contact, style: .fullName) ?? "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
    ]

    if brief {
        // Include all emails and phones as flat arrays for brief listing
        if !contact.emailAddresses.isEmpty {
            dict["emails"] = contact.emailAddresses.map { $0.value as String }
        }
        if !contact.phoneNumbers.isEmpty {
            dict["phones"] = contact.phoneNumbers.map { $0.value.stringValue }
        }
        if !contact.organizationName.isEmpty {
            dict["organization"] = contact.organizationName
        }
        if let birthday = contact.birthday {
            var birthdayDict: [String: Any] = [:]
            if let year = birthday.year { birthdayDict["year"] = year }
            if let month = birthday.month { birthdayDict["month"] = month }
            if let day = birthday.day { birthdayDict["day"] = day }
            dict["birthday"] = birthdayDict
        }
        return dict
    }

    // Full details
    if !contact.middleName.isEmpty { dict["middleName"] = contact.middleName }
    if !contact.namePrefix.isEmpty { dict["namePrefix"] = contact.namePrefix }
    if !contact.nameSuffix.isEmpty { dict["nameSuffix"] = contact.nameSuffix }
    if !contact.nickname.isEmpty { dict["nickname"] = contact.nickname }
    if !contact.previousFamilyName.isEmpty { dict["previousFamilyName"] = contact.previousFamilyName }
    if !contact.phoneticGivenName.isEmpty { dict["phoneticGivenName"] = contact.phoneticGivenName }
    if !contact.phoneticMiddleName.isEmpty { dict["phoneticMiddleName"] = contact.phoneticMiddleName }
    if !contact.phoneticFamilyName.isEmpty { dict["phoneticFamilyName"] = contact.phoneticFamilyName }
    if !contact.phoneticOrganizationName.isEmpty { dict["phoneticOrganizationName"] = contact.phoneticOrganizationName }
    if !contact.organizationName.isEmpty { dict["organization"] = contact.organizationName }
    if !contact.jobTitle.isEmpty { dict["jobTitle"] = contact.jobTitle }
    if !contact.departmentName.isEmpty { dict["department"] = contact.departmentName }

    if !contact.emailAddresses.isEmpty {
        dict["emails"] = contact.emailAddresses.map { labeled in
            [
                "label": CNLabeledValue<NSString>.localizedString(forLabel: labeled.label ?? ""),
                "value": labeled.value as String
            ]
        }
    }

    if !contact.phoneNumbers.isEmpty {
        dict["phones"] = contact.phoneNumbers.map { labeled in
            [
                "label": CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: labeled.label ?? ""),
                "value": labeled.value.stringValue
            ]
        }
    }

    if !contact.postalAddresses.isEmpty {
        dict["addresses"] = contact.postalAddresses.map { labeled in
            let addr = labeled.value
            return [
                "label": CNLabeledValue<CNPostalAddress>.localizedString(forLabel: labeled.label ?? ""),
                "street": addr.street,
                "city": addr.city,
                "state": addr.state,
                "postalCode": addr.postalCode,
                "country": addr.country
            ]
        }
    }

    if !contact.urlAddresses.isEmpty {
        dict["urls"] = contact.urlAddresses.map { labeled in
            [
                "label": CNLabeledValue<NSString>.localizedString(forLabel: labeled.label ?? ""),
                "value": labeled.value as String
            ]
        }
    }

    if !contact.instantMessageAddresses.isEmpty {
        dict["instantMessages"] = contact.instantMessageAddresses.map { labeled in
            [
                "label": CNLabeledValue<CNInstantMessageAddress>.localizedString(forLabel: labeled.label ?? ""),
                "service": labeled.value.service,
                "username": labeled.value.username
            ]
        }
    }

    if let birthday = contact.birthday {
        var birthdayDict: [String: Any] = [:]
        if let year = birthday.year { birthdayDict["year"] = year }
        if let month = birthday.month { birthdayDict["month"] = month }
        if let day = birthday.day { birthdayDict["day"] = day }
        dict["birthday"] = birthdayDict
    }

    if let nonGregorianBirthday = contact.nonGregorianBirthday {
        var bdayDict: [String: Any] = [:]
        if let year = nonGregorianBirthday.year { bdayDict["year"] = year }
        if let month = nonGregorianBirthday.month { bdayDict["month"] = month }
        if let day = nonGregorianBirthday.day { bdayDict["day"] = day }
        if let cal = nonGregorianBirthday.calendar {
            bdayDict["calendar"] = "\(cal.identifier)"
        }
        dict["nonGregorianBirthday"] = bdayDict
    }

    if !contact.dates.isEmpty {
        dict["dates"] = contact.dates.map { labeled in
            var dateDict: [String: Any] = [
                "label": CNLabeledValue<NSDateComponents>.localizedString(forLabel: labeled.label ?? "")
            ]
            let comps = labeled.value as DateComponents
            if let year = comps.year { dateDict["year"] = year }
            if let month = comps.month { dateDict["month"] = month }
            if let day = comps.day { dateDict["day"] = day }
            return dateDict
        }
    }

    // Notes may not be available due to macOS privacy restrictions
    if contact.isKeyAvailable(CNContactNoteKey), !contact.note.isEmpty {
        dict["notes"] = contact.note
    }

    // Check if image keys are available before accessing
    let hasImageKey = contact.isKeyAvailable(CNContactImageDataAvailableKey)
    dict["hasImage"] = hasImageKey ? contact.imageDataAvailable : false
    dict["contactType"] = contact.contactType == .person ? "person" : "organization"

    // Include image data as base64 if available (prefer thumbnail for smaller payload)
    if hasImageKey && contact.imageDataAvailable {
        if contact.isKeyAvailable(CNContactThumbnailImageDataKey),
           let thumbnailData = contact.thumbnailImageData {
            dict["imageBase64"] = thumbnailData.base64EncodedString()
            dict["imageType"] = "thumbnail"
        } else if contact.isKeyAvailable(CNContactImageDataKey),
                  let imageData = contact.imageData {
            dict["imageBase64"] = imageData.base64EncodedString()
            dict["imageType"] = "full"
        }
    }

    if !contact.contactRelations.isEmpty {
        dict["relations"] = contact.contactRelations.map { labeled in
            [
                "label": CNLabeledValue<CNContactRelation>.localizedString(forLabel: labeled.label ?? ""),
                "name": labeled.value.name
            ]
        }
    }

    if !contact.socialProfiles.isEmpty {
        dict["socialProfiles"] = contact.socialProfiles.map { labeled in
            [
                "service": labeled.value.service,
                "username": labeled.value.username,
                "url": labeled.value.urlString
            ]
        }
    }

    return dict
}

// MARK: - Container Filtering

// containers(matching: nil) returns real accounts but also Exchange default lists as Contacts groups (Apple bug).
// Strip those by excluding any container whose identifier also appears in groups(matching: nil).
func allAccountContainers() throws -> [CNContainer] {
    let all = try contactStore.containers(matching: nil)
    let groupIds = Set(try contactStore.groups(matching: nil).map { $0.identifier })
    return all.filter { !groupIds.contains($0.identifier) }
}

func filteredContainers(config: PIMConfiguration) throws -> [CNContainer] {
    let accounts = try allAccountContainers()
    return ItemFilter.filter(items: accounts, config: config.contacts, name: { $0.name }, id: { $0.identifier })
}

func fetchContactsFromAllowedContainers(config: PIMConfiguration) throws -> [CNContact] {
    let allowed = try filteredContainers(config: config)
    var contacts: [CNContact] = []
    for container in allowed {
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        request.predicate = CNContact.predicateForContactsInContainer(withIdentifier: container.identifier)
        request.unifyResults = false
        request.mutableObjects = false
        try contactStore.enumerateContacts(with: request) { contact, _ in
            contacts.append(contact)
        }
    }
    return contacts
}

// MARK: - Scoped Contact Resolution

enum ContactAccessMode {
    case fullAccess
    case scopedContainers(Set<String>)
}

struct AuthorizedRawContact {
    let contact: CNContact
    let accountContainer: CNContainer
}

func contactAccessMode(config: PIMConfiguration) -> ContactAccessMode {
    guard config.contacts.mode != .all else { return .fullAccess }
    let allowed = (try? filteredContainers(config: config)) ?? []
    return .scopedContainers(Set(allowed.map { $0.identifier }))
}

func resolveAccountContainer(forContactId contactId: String) throws -> CNContainer? {
    let containerPred = CNContainer.predicateForContainerOfContact(withIdentifier: contactId)
    let containers = try contactStore.containers(matching: containerPred)
    guard let direct = containers.first else { return nil }

    let groupIds = Set(try contactStore.groups(matching: nil).map { $0.identifier })
    if groupIds.contains(direct.identifier) {
        let parentPred = CNContainer.predicateForContainerOfGroup(withIdentifier: direct.identifier)
        return try contactStore.containers(matching: parentPred).first
    }
    return direct
}

func isMultiSourceUnifiedId(_ contactId: String) throws -> Bool {
    let containerPred = CNContainer.predicateForContainerOfContact(withIdentifier: contactId)
    let containers = try contactStore.containers(matching: containerPred)
    return containers.isEmpty
}

func resolveAuthorizedBackings(
    forContactId contactId: String,
    allowedContainerIds: Set<String>,
    keysToFetch keys: [CNKeyDescriptor]
) throws -> [AuthorizedRawContact] {
    let unified = try contactStore.unifiedContact(
        withIdentifier: contactId,
        keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]
    )

    let request = CNContactFetchRequest(keysToFetch: keys)
    request.predicate = CNContact.predicateForContacts(withIdentifiers: [unified.identifier])
    request.unifyResults = false
    request.mutableObjects = false

    var authorized: [AuthorizedRawContact] = []
    try contactStore.enumerateContacts(with: request) { contact, _ in
        guard let account = try? resolveAccountContainer(forContactId: contact.identifier) else { return }
        if allowedContainerIds.contains(account.identifier) {
            authorized.append(AuthorizedRawContact(contact: contact, accountContainer: account))
        }
    }
    return authorized
}

/// Validate that a contact ID is a backing ID in an allowed container.
/// Returns the resolved account container on success.
@discardableResult
func validateScopedContactAccess(id: String, allowedIds: Set<String>) throws -> CNContainer {
    guard try !isMultiSourceUnifiedId(id) else {
        throw CLIError.invalidInput("Use a specific contact ID from list or search.")
    }
    guard let account = try resolveAccountContainer(forContactId: id) else {
        throw CLIError.notFound("Contact not found: \(id)")
    }
    guard allowedIds.contains(account.identifier) else {
        throw CLIError.accessDenied("Contact is not in your allowed accounts.")
    }
    return account
}

// MARK: - Commands

struct ListContainers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "containers",
        abstract: "List all contact account containers"
    )

    @OptionGroup var pimOptions: PIMOptions

    func run() async throws {
        try await requestContactsAccess()
        let config = pimOptions.loadConfig()
        try checkContactsEnabled(config: config)

        let containers = try filteredContainers(config: config)
        let result = containers.map { containerToDict($0) }

        outputJSON([
            "success": true,
            "containers": result,
            "count": result.count
        ])
    }
}

struct ListGroups: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "groups",
        abstract: "List all contact groups"
    )

    @OptionGroup var pimOptions: PIMOptions

    func run() async throws {
        try await requestContactsAccess()
        let config = pimOptions.loadConfig()
        try checkContactsEnabled(config: config)
        let mode = contactAccessMode(config: config)

        var groups: [CNGroup]
        switch mode {
        case .fullAccess:
            groups = try contactStore.groups(matching: nil)
        case .scopedContainers(let allowedIds):
            let allGroups = try contactStore.groups(matching: nil)
            groups = allGroups.filter { group in
                guard let container = try? contactStore.containers(
                    matching: CNContainer.predicateForContainerOfGroup(withIdentifier: group.identifier)
                ).first else {
                    return false
                }
                return allowedIds.contains(container.identifier)
            }
        }
        let result = groups.map { groupToDict($0) }

        outputJSON([
            "success": true,
            "groups": result
        ])
    }
}

struct ListContacts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List contacts"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "Group name or ID to filter by")
    var group: String?

    @Option(name: .long, help: "Maximum number of contacts")
    var limit: Int = 100

    func run() async throws {
        try await requestContactsAccess()
        let config = pimOptions.loadConfig()
        try checkContactsEnabled(config: config)
        let mode = contactAccessMode(config: config)

        var contacts: [CNContact] = []

        if let groupFilter = group {
            // Find the group
            let groups = try contactStore.groups(matching: nil)
            guard let matchedGroup = groups.first(where: { $0.identifier == groupFilter || $0.name.lowercased() == groupFilter.lowercased() }) else {
                throw CLIError.notFound("Group not found: \(groupFilter)")
            }

            // Fetch contacts in group
            let predicate = CNContact.predicateForContactsInGroup(withIdentifier: matchedGroup.identifier)

            switch mode {
            case .fullAccess:
                contacts = try contactStore.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)
            case .scopedContainers(let allowedIds):
                let containerPred = CNContainer.predicateForContainerOfGroup(withIdentifier: matchedGroup.identifier)
                if let container = try contactStore.containers(matching: containerPred).first {
                    guard allowedIds.contains(container.identifier) else {
                        throw CLIError.accessDenied("Group is not in your allowed accounts.")
                    }
                }
                let request = CNContactFetchRequest(keysToFetch: keysToFetch)
                request.predicate = predicate
                request.unifyResults = false
                request.mutableObjects = false
                try contactStore.enumerateContacts(with: request) { contact, _ in
                    contacts.append(contact)
                }
            }
        } else {
            // Fetch all contacts
            switch mode {
            case .fullAccess:
                let request = CNContactFetchRequest(keysToFetch: keysToFetch)
                request.sortOrder = .familyName
                try contactStore.enumerateContacts(with: request) { contact, stop in
                    contacts.append(contact)
                    if contacts.count >= limit {
                        stop.pointee = true
                    }
                }
            case .scopedContainers:
                contacts = try fetchContactsFromAllowedContainers(config: config)
                if contacts.count > limit {
                    contacts = Array(contacts.prefix(limit))
                }
            }
        }

        let result = contacts.prefix(limit).map { contactToDict($0, brief: true) }

        outputJSON([
            "success": true,
            "contacts": Array(result),
            "count": result.count
        ])
    }
}

struct SearchContacts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search contacts by name, email, or phone"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Argument(help: "Search query")
    var query: String

    @Option(name: .long, help: "Maximum results")
    var limit: Int = 50

    func run() async throws {
        try await requestContactsAccess()
        let config = pimOptions.loadConfig()
        try checkContactsEnabled(config: config)
        let mode = contactAccessMode(config: config)

        var contacts: [CNContact]

        switch mode {
        case .fullAccess:
            let predicate = CNContact.predicateForContacts(matchingName: query)
            contacts = try contactStore.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)

            // Also search by email and phone if name search returns few results
            if contacts.count < limit {
                let allContacts = try fetchAllContactsUnfiltered()
                contacts.append(contentsOf: searchByEmailPhone(allContacts, excluding: contacts))
            }

        case .scopedContainers(let allowedIds):
            let nameRequest = CNContactFetchRequest(keysToFetch: keysToFetch)
            nameRequest.predicate = CNContact.predicateForContacts(matchingName: query)
            nameRequest.unifyResults = false
            nameRequest.mutableObjects = false

            var nameMatches: [CNContact] = []
            try contactStore.enumerateContacts(with: nameRequest) { contact, _ in
                guard let account = try? resolveAccountContainer(forContactId: contact.identifier) else { return }
                if allowedIds.contains(account.identifier) {
                    nameMatches.append(contact)
                }
            }
            contacts = nameMatches

            if contacts.count < limit {
                let allAllowed = try fetchContactsFromAllowedContainers(config: config)
                contacts.append(contentsOf: searchByEmailPhone(allAllowed, excluding: contacts))
            }
        }

        let result = contacts.prefix(limit).map { contactToDict($0, brief: true) }

        outputJSON([
            "success": true,
            "query": query,
            "contacts": Array(result),
            "count": result.count
        ])
    }

    private func searchByEmailPhone(_ pool: [CNContact], excluding: [CNContact]) -> [CNContact] {
        let queryLower = query.lowercased()
        let queryDigits = query.filter { $0.isNumber }
        let existingIds = Set(excluding.map { $0.identifier })

        return pool.filter { contact in
            // Skip if already found by name
            if existingIds.contains(contact.identifier) { return false }

            // Check emails
            for email in contact.emailAddresses {
                if (email.value as String).lowercased().contains(queryLower) { return true }
            }

            // Check phones (strip non-digits for comparison)
            if !queryDigits.isEmpty {
                for phone in contact.phoneNumbers {
                    let phoneDigits = phone.value.stringValue.filter { $0.isNumber }
                    if phoneDigits.contains(queryDigits) || queryDigits.contains(phoneDigits) { return true }
                }
            }
            return false
        }
    }

    private func fetchAllContactsUnfiltered() throws -> [CNContact] {
        var contacts: [CNContact] = []
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)

        try contactStore.enumerateContacts(with: request) { contact, _ in
            contacts.append(contact)
        }

        return contacts
    }
}

struct GetContact: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get full details for a contact"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "Contact ID")
    var id: String

    func run() async throws {
        try await requestContactsAccess()
        let config = pimOptions.loadConfig()
        try checkContactsEnabled(config: config)
        let mode = contactAccessMode(config: config)

        switch mode {
        case .fullAccess:
            let predicate = CNContact.predicateForContacts(withIdentifiers: [id])
            let contacts = try contactStore.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)

            guard let contact = contacts.first else {
                throw CLIError.notFound("Contact not found: \(id)")
            }

            outputJSON([
                "success": true,
                "contact": contactToDict(contact, brief: false)
            ])

        case .scopedContainers(let allowedIds):
            let account = try validateScopedContactAccess(id: id, allowedIds: allowedIds)

            let request = CNContactFetchRequest(keysToFetch: keysToFetch)
            request.predicate = CNContact.predicateForContacts(withIdentifiers: [id])
            request.unifyResults = false
            request.mutableObjects = false
            var contact: CNContact?
            try contactStore.enumerateContacts(with: request) { c, stop in
                contact = c
                stop.pointee = true
            }
            guard let found = contact else {
                throw CLIError.notFound("Contact not found: \(id)")
            }

            var contactDict = contactToDict(found, brief: false)
            contactDict["sourceContainer"] = account.name

            let related = try resolveAuthorizedBackings(
                forContactId: id, allowedContainerIds: allowedIds, keysToFetch: keysToFetch
            ).filter { $0.contact.identifier != id }

            let relatedDicts: [[String: Any]] = related.map { arc in
                var d = contactToDict(arc.contact, brief: false)
                d["sourceContainer"] = arc.accountContainer.name
                return d
            }

            outputJSON([
                "success": true,
                "contact": contactDict,
                "relatedContacts": relatedDicts
            ])
        }
    }
}

struct CreateContact: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new contact"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "Target container/account name or ID")
    var container: String?

    // Name fields
    @Option(name: .long, help: "First name")
    var firstName: String?

    @Option(name: .long, help: "Last name")
    var lastName: String?

    @Option(name: .long, help: "Full name (alternative to first/last)")
    var name: String?

    @Option(name: .long, help: "Middle name")
    var middleName: String?

    @Option(name: .long, help: "Name prefix (e.g. Dr., Mr.)")
    var namePrefix: String?

    @Option(name: .long, help: "Name suffix (e.g. Jr., III)")
    var nameSuffix: String?

    @Option(name: .long, help: "Nickname")
    var nickname: String?

    @Option(name: .long, help: "Previous family name (maiden name)")
    var previousFamilyName: String?

    // Phonetic names
    @Option(name: .long, help: "Phonetic first name")
    var phoneticGivenName: String?

    @Option(name: .long, help: "Phonetic middle name")
    var phoneticMiddleName: String?

    @Option(name: .long, help: "Phonetic last name")
    var phoneticFamilyName: String?

    @Option(name: .long, help: "Phonetic organization name")
    var phoneticOrganizationName: String?

    // Organization
    @Option(name: .long, help: "Organization/company name")
    var organization: String?

    @Option(name: .long, help: "Job title")
    var jobTitle: String?

    @Option(name: .long, help: "Department name")
    var department: String?

    // Contact type
    @Option(name: .long, help: "Contact type: person or organization")
    var contactType: String?

    // Simple communication (backward compatible)
    @Option(name: .long, help: "Email address (simple, uses 'work' label)")
    var email: String?

    @Option(name: .long, help: "Phone number (simple, uses 'main' label)")
    var phone: String?

    // Rich labeled arrays (JSON)
    @Option(name: .long, help: "Emails as JSON array: [{\"label\":\"work\",\"value\":\"user@example.com\"}]")
    var emails: String?

    @Option(name: .long, help: "Phones as JSON array: [{\"label\":\"mobile\",\"value\":\"555-0100\"}]")
    var phones: String?

    @Option(name: .long, help: "Addresses as JSON array: [{\"label\":\"home\",\"street\":\"...\",\"city\":\"...\",\"state\":\"...\",\"postalCode\":\"...\",\"country\":\"...\"}]")
    var addresses: String?

    @Option(name: .long, help: "URLs as JSON array: [{\"label\":\"homepage\",\"value\":\"https://...\"}]")
    var urls: String?

    @Option(name: .long, help: "Social profiles as JSON array: [{\"service\":\"Twitter\",\"username\":\"...\",\"url\":\"...\"}]")
    var socialProfiles: String?

    @Option(name: .long, help: "Instant messages as JSON array: [{\"service\":\"Skype\",\"username\":\"...\"}]")
    var instantMessages: String?

    @Option(name: .long, help: "Relations as JSON array: [{\"label\":\"spouse\",\"name\":\"...\"}]")
    var relations: String?

    // Dates
    @Option(name: .long, help: "Birthday (YYYY-MM-DD or MM-DD)")
    var birthday: String?

    @Option(name: .long, help: "Dates as JSON array: [{\"label\":\"anniversary\",\"month\":6,\"day\":15,\"year\":2020}]")
    var dates: String?

    // Notes
    @Option(name: .long, help: "Notes")
    var notes: String?

    func run() async throws {
        try await requestContactsAccess()
        let config = pimOptions.loadConfig()
        try checkContactsEnabled(config: config)

        var targetContainerId: String? = nil
        if let containerHint = container {
            let accounts = try allAccountContainers()
            guard let matched = accounts.first(where: { $0.identifier == containerHint || $0.name.lowercased() == containerHint.lowercased() }) else {
                throw CLIError.notFound("Container not found: \(containerHint)")
            }
            guard ItemFilter.isAllowed(name: matched.name, id: matched.identifier, config: config.contacts) else {
                throw CLIError.accessDenied("Target container is not in your allowed accounts.")
            }
            targetContainerId = matched.identifier
        } else if case .scopedContainers(let allowedIds) = contactAccessMode(config: config) {
            // Without --container, Contacts saves to the system default account.
            // In scoped mode that default may be disallowed (e.g. iCloud while only Exchange is allowed),
            // which would bypass the allowlist. Resolve and validate explicitly.
            let defaultId = contactStore.defaultContainerIdentifier()
            if allowedIds.contains(defaultId) {
                targetContainerId = defaultId
            } else if allowedIds.count == 1, let onlyAllowed = allowedIds.first {
                targetContainerId = onlyAllowed
            } else {
                throw CLIError.invalidInput("System default contacts account is not in your allowed accounts. Pass --container explicitly.")
            }
        }

        let contact = CNMutableContact()

        // Name
        if let fullName = name {
            let parts = fullName.split(separator: " ")
            if parts.count == 1 {
                contact.givenName = String(parts[0])
            } else if parts.count >= 2 {
                contact.givenName = String(parts[0])
                contact.familyName = parts.dropFirst().joined(separator: " ")
            }
        } else {
            if let first = firstName { contact.givenName = first }
            if let last = lastName { contact.familyName = last }
        }

        if let v = middleName { contact.middleName = v }
        if let v = namePrefix { contact.namePrefix = v }
        if let v = nameSuffix { contact.nameSuffix = v }
        if let v = nickname { contact.nickname = v }
        if let v = previousFamilyName { contact.previousFamilyName = v }

        // Phonetic
        if let v = phoneticGivenName { contact.phoneticGivenName = v }
        if let v = phoneticMiddleName { contact.phoneticMiddleName = v }
        if let v = phoneticFamilyName { contact.phoneticFamilyName = v }
        if let v = phoneticOrganizationName { contact.phoneticOrganizationName = v }

        // Organization
        if let org = organization { contact.organizationName = org }
        if let title = jobTitle { contact.jobTitle = title }
        if let dept = department { contact.departmentName = dept }

        // Contact type
        if let ct = contactType?.lowercased() {
            contact.contactType = ct == "organization" ? .organization : .person
        }

        // Emails (JSON array takes priority over simple --email)
        if let emailsJSON = emails {
            contact.emailAddresses = try parseEmails(emailsJSON)
        } else if let emailAddr = email {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: emailAddr as NSString)]
        }

        // Phones (JSON array takes priority over simple --phone)
        if let phonesJSON = phones {
            contact.phoneNumbers = try parsePhones(phonesJSON)
        } else if let phoneNum = phone {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phoneNum))]
        }

        // Structured arrays
        if let json = addresses { contact.postalAddresses = try parseAddresses(json) }
        if let json = urls { contact.urlAddresses = try parseURLs(json) }
        if let json = socialProfiles { contact.socialProfiles = try parseSocialProfiles(json) }
        if let json = instantMessages { contact.instantMessageAddresses = try parseInstantMessages(json) }
        if let json = relations { contact.contactRelations = try parseRelations(json) }
        if let json = dates { contact.dates = try parseDates(json) }

        // Birthday
        if let birthdayStr = birthday {
            contact.birthday = try parseBirthday(birthdayStr)
        }

        // Notes
        if let note = notes { contact.note = note }

        let saveRequest = CNSaveRequest()
        saveRequest.add(contact, toContainerWithIdentifier: targetContainerId)
        try contactStore.execute(saveRequest)

        outputJSON([
            "success": true,
            "message": "Contact created successfully",
            "contact": contactToDict(contact, brief: false)
        ])
    }
}

struct UpdateContact: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an existing contact"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "Contact ID to update")
    var id: String

    // Name fields
    @Option(name: .long, help: "New first name")
    var firstName: String?

    @Option(name: .long, help: "New last name")
    var lastName: String?

    @Option(name: .long, help: "New middle name")
    var middleName: String?

    @Option(name: .long, help: "New name prefix (e.g. Dr., Mr.)")
    var namePrefix: String?

    @Option(name: .long, help: "New name suffix (e.g. Jr., III)")
    var nameSuffix: String?

    @Option(name: .long, help: "New nickname")
    var nickname: String?

    @Option(name: .long, help: "New previous family name (maiden name)")
    var previousFamilyName: String?

    // Phonetic names
    @Option(name: .long, help: "New phonetic first name")
    var phoneticGivenName: String?

    @Option(name: .long, help: "New phonetic middle name")
    var phoneticMiddleName: String?

    @Option(name: .long, help: "New phonetic last name")
    var phoneticFamilyName: String?

    @Option(name: .long, help: "New phonetic organization name")
    var phoneticOrganizationName: String?

    // Organization
    @Option(name: .long, help: "New organization")
    var organization: String?

    @Option(name: .long, help: "New job title")
    var jobTitle: String?

    @Option(name: .long, help: "New department name")
    var department: String?

    // Contact type
    @Option(name: .long, help: "Contact type: person or organization")
    var contactType: String?

    // Simple communication (backward compatible - replaces primary)
    @Option(name: .long, help: "New email (replaces primary)")
    var email: String?

    @Option(name: .long, help: "New phone (replaces primary)")
    var phone: String?

    // Rich labeled arrays (JSON - replaces ALL entries)
    @Option(name: .long, help: "Replace all emails: [{\"label\":\"work\",\"value\":\"user@example.com\"}]")
    var emails: String?

    @Option(name: .long, help: "Replace all phones: [{\"label\":\"mobile\",\"value\":\"555-0100\"}]")
    var phones: String?

    @Option(name: .long, help: "Replace all addresses: [{\"label\":\"home\",\"street\":\"...\",\"city\":\"...\",\"state\":\"...\",\"postalCode\":\"...\",\"country\":\"...\"}]")
    var addresses: String?

    @Option(name: .long, help: "Replace all URLs: [{\"label\":\"homepage\",\"value\":\"https://...\"}]")
    var urls: String?

    @Option(name: .long, help: "Replace all social profiles: [{\"service\":\"Twitter\",\"username\":\"...\",\"url\":\"...\"}]")
    var socialProfiles: String?

    @Option(name: .long, help: "Replace all instant messages: [{\"service\":\"Skype\",\"username\":\"...\"}]")
    var instantMessages: String?

    @Option(name: .long, help: "Replace all relations: [{\"label\":\"spouse\",\"name\":\"...\"}]")
    var relations: String?

    // Dates
    @Option(name: .long, help: "New birthday (YYYY-MM-DD or MM-DD)")
    var birthday: String?

    @Option(name: .long, help: "Replace all dates: [{\"label\":\"anniversary\",\"month\":6,\"day\":15,\"year\":2020}]")
    var dates: String?

    // Notes
    @Option(name: .long, help: "New notes")
    var notes: String?

    func run() async throws {
        try await requestContactsAccess()
        let config = pimOptions.loadConfig()
        try checkContactsEnabled(config: config)
        let mode = contactAccessMode(config: config)

        switch mode {
        case .fullAccess:
            let maxAttempts = 3
            var attempts = 0

            while true {
                attempts += 1

                // First attempt edits the unified contact (the normal, historical
                // behavior). If the save hits a merge conflict, retry against the
                // raw source card instead: for linked contacts the unified save
                // fails *deterministically* (CoreData 134092 while faulting
                // multivalue entries owned by the other linked card), so
                // re-fetching the unified view again can never succeed — and each
                // failed unified save risks partially applying. The raw-card path
                // matches Contacts.app behavior and the scopedContainers branch.
                let unified = (attempts == 1)
                guard let existingContact = try fetchContactForMutation(id: id, unified: unified) else {
                    throw CLIError.notFound("Contact not found: \(id)")
                }

                let contact = existingContact.mutableCopy() as! CNMutableContact

                try applyContactMutations(to: contact)

                let saveRequest = CNSaveRequest()
                saveRequest.update(contact)

                do {
                    try contactStore.execute(saveRequest)
                } catch {
                    // CoreData 134092 = NSManagedObjectMergeError. Either a
                    // transient iCloud sync conflict, or a deterministic
                    // faulting failure when the card has a note and this
                    // process lacks the notes entitlement. May appear at top
                    // level or nested in underlyingErrors.
                    if isMergeConflict(error) {
                        if attempts < maxAttempts {
                            fputs("Warning: Merge conflict (attempt \(attempts)/\(maxAttempts)). Re-fetching source card and retrying...\n", stderr)
                            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                            continue
                        }
                        if let result = try recoverViaContactsApp() {
                            outputJSON(result)
                            return
                        }
                    }
                    throw error
                }

                outputJSON([
                    "success": true,
                    "message": "Contact updated successfully",
                    "contact": contactToDict(contact, brief: false)
                ])
                return
            }

        case .scopedContainers(let allowedIds):
            try validateScopedContactAccess(id: id, allowedIds: allowedIds)

            let maxAttempts = 3
            var attempts = 0

            while true {
                attempts += 1

                guard let existingContact = try fetchContactForMutation(id: id, unified: false) else {
                    throw CLIError.notFound("Contact not found: \(id)")
                }

                let contact = existingContact.mutableCopy() as! CNMutableContact
                try applyContactMutations(to: contact)

                let saveRequest = CNSaveRequest()
                saveRequest.update(contact)

                do {
                    try contactStore.execute(saveRequest)
                } catch {
                    // CoreData 134092 = NSManagedObjectMergeError. Either a
                    // transient iCloud sync conflict, or a deterministic
                    // faulting failure when the card has a note and this
                    // process lacks the notes entitlement. May appear at top
                    // level or nested in underlyingErrors.
                    if isMergeConflict(error) {
                        if attempts < maxAttempts {
                            fputs("Warning: Merge conflict (attempt \(attempts)/\(maxAttempts)). Re-fetching and retrying...\n", stderr)
                            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                            continue
                        }
                        if let result = try recoverViaContactsApp() {
                            outputJSON(result)
                            return
                        }
                    }
                    throw error
                }

                outputJSON([
                    "success": true,
                    "message": "Contact updated successfully",
                    "contact": contactToDict(contact, brief: false)
                ])
                return
            }
        }
    }

    /// True when this update touches emails or phones (the multivalue fields
    /// covered by the Contacts.app fallback).
    private var hasCommunicationMutations: Bool {
        emails != nil || phones != nil || email != nil || phone != nil
    }

    /// True when this update touches anything OTHER than emails/phones.
    private var hasNonCommunicationMutations: Bool {
        firstName != nil || lastName != nil || middleName != nil
            || namePrefix != nil || nameSuffix != nil || nickname != nil
            || previousFamilyName != nil || phoneticGivenName != nil
            || phoneticMiddleName != nil || phoneticFamilyName != nil
            || phoneticOrganizationName != nil || organization != nil
            || jobTitle != nil || department != nil || contactType != nil
            || addresses != nil || urls != nil || socialProfiles != nil
            || instantMessages != nil || relations != nil || birthday != nil
            || dates != nil || notes != nil
    }

    /// Apply email/phone changes through Contacts.app (AppleScript).
    ///
    /// Processes without the com.apple.developer.contacts.notes entitlement
    /// cannot execute a CNSaveRequest that touches multivalue fields on a card
    /// that has a note: the store faults the unauthorized note property during
    /// the write and fails with CoreData 134092 — deterministically, and
    /// sometimes after partially applying. Contacts.app is entitled, so routing
    /// the same edit through it succeeds. Returns false when this update has no
    /// email/phone changes for the fallback to apply.
    private func applyCommunicationsViaContactsApp() throws -> Bool {
        guard hasCommunicationMutations else { return false }

        var lines: [String] = [
            "tell application \"Contacts\"",
            "set p to first person whose id is \"\(appleScriptEscaped(id))\"",
        ]

        if let emailsJSON = emails {
            let items = try parseJSONArray(emailsJSON)
            lines.append("repeat while (count of emails of p) > 0")
            lines.append("delete email 1 of p")
            lines.append("end repeat")
            for item in items {
                let value = appleScriptEscaped(item["value"] as? String ?? "")
                let label = appleScriptEscaped(item["label"] as? String ?? "other")
                lines.append(
                    "make new email at end of emails of p with properties {label:\"\(label)\", value:\"\(value)\"}"
                )
            }
        } else if let emailAddr = email {
            let value = appleScriptEscaped(emailAddr)
            lines.append("if (count of emails of p) > 0 then")
            lines.append("set value of email 1 of p to \"\(value)\"")
            lines.append("else")
            lines.append(
                "make new email at end of emails of p with properties {label:\"work\", value:\"\(value)\"}"
            )
            lines.append("end if")
        }

        if let phonesJSON = phones {
            let items = try parseJSONArray(phonesJSON)
            lines.append("repeat while (count of phones of p) > 0")
            lines.append("delete phone 1 of p")
            lines.append("end repeat")
            for item in items {
                let value = appleScriptEscaped(item["value"] as? String ?? "")
                let label = appleScriptEscaped(item["label"] as? String ?? "other")
                lines.append(
                    "make new phone at end of phones of p with properties {label:\"\(label)\", value:\"\(value)\"}"
                )
            }
        } else if let phoneNum = phone {
            let value = appleScriptEscaped(phoneNum)
            lines.append("if (count of phones of p) > 0 then")
            lines.append("set value of phone 1 of p to \"\(value)\"")
            lines.append("else")
            lines.append(
                "make new phone at end of phones of p with properties {label:\"main\", value:\"\(value)\"}"
            )
            lines.append("end if")
        }

        lines.append("save")
        lines.append("end tell")

        try runAppleScript(lines.joined(separator: "\n"))
        return true
    }

    /// After the Contacts.app fallback has applied email/phone changes, apply
    /// any remaining (non-communication) mutations natively — scalar saves are
    /// unaffected by the notes-entitlement bug.
    private func saveRemainingMutationsNatively() throws {
        guard hasNonCommunicationMutations else { return }
        guard let existing = try fetchContactForMutation(id: id, unified: false) else {
            throw CLIError.notFound("Contact not found: \(id)")
        }
        let contact = existing.mutableCopy() as! CNMutableContact
        try applyContactMutations(to: contact, skipCommunications: true)
        let saveRequest = CNSaveRequest()
        saveRequest.update(contact)
        try contactStore.execute(saveRequest)
    }

    /// Shared final-failure handler: when the native save keeps hitting
    /// CoreData 134092, route email/phone changes through Contacts.app and
    /// finish the rest natively. Returns the output dictionary on success, or
    /// nil when the fallback does not apply.
    private func recoverViaContactsApp() throws -> [String: Any]? {
        fputs(
            "Warning: Native save failed with CoreData 134092; applying email/phone changes via Contacts.app (this card has a note, which processes without the com.apple.developer.contacts.notes entitlement cannot rewrite alongside multivalue changes).\n",
            stderr
        )
        guard try applyCommunicationsViaContactsApp() else { return nil }
        try saveRemainingMutationsNatively()
        guard let final = try fetchContactForMutation(id: id, unified: true) else {
            throw CLIError.notFound("Contact not found after update: \(id)")
        }
        return [
            "success": true,
            "message": "Contact updated successfully (via Contacts.app fallback)",
            "contact": contactToDict(final, brief: false)
        ]
    }

    private func applyContactMutations(
        to contact: CNMutableContact,
        skipCommunications: Bool = false
    ) throws {
        // Name fields
        if let first = firstName { contact.givenName = first }
        if let last = lastName { contact.familyName = last }
        if let v = middleName { contact.middleName = v }
        if let v = namePrefix { contact.namePrefix = v }
        if let v = nameSuffix { contact.nameSuffix = v }
        if let v = nickname { contact.nickname = v }
        if let v = previousFamilyName { contact.previousFamilyName = v }

        // Phonetic
        if let v = phoneticGivenName { contact.phoneticGivenName = v }
        if let v = phoneticMiddleName { contact.phoneticMiddleName = v }
        if let v = phoneticFamilyName { contact.phoneticFamilyName = v }
        if let v = phoneticOrganizationName { contact.phoneticOrganizationName = v }

        // Organization
        if let org = organization { contact.organizationName = org }
        if let title = jobTitle { contact.jobTitle = title }
        if let dept = department { contact.departmentName = dept }

        // Contact type
        if let ct = contactType?.lowercased() {
            contact.contactType = ct == "organization" ? .organization : .person
        }

        if skipCommunications {
            try applyNonCommunicationMutations(to: contact)
            return
        }
        try applyCommunicationMutations(to: contact)
        try applyNonCommunicationMutations(to: contact)
    }

    private func applyCommunicationMutations(to contact: CNMutableContact) throws {
        // Emails (JSON array replaces all; simple --email replaces primary).
        // Existing CNLabeledValue instances are reused for unchanged values so
        // their identifiers survive — see mergeLabeledStrings for why.
        if let emailsJSON = emails {
            contact.emailAddresses = mergeLabeledStrings(
                existing: contact.emailAddresses,
                desired: try parseEmails(emailsJSON)
            )
        } else if let emailAddr = email {
            if contact.emailAddresses.isEmpty {
                contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: emailAddr as NSString)]
            } else {
                contact.emailAddresses[0] = contact.emailAddresses[0].settingValue(emailAddr as NSString)
            }
        }

        // Phones (JSON array replaces all; simple --phone replaces primary)
        if let phonesJSON = phones {
            contact.phoneNumbers = mergeLabeledPhones(
                existing: contact.phoneNumbers,
                desired: try parsePhones(phonesJSON)
            )
        } else if let phoneNum = phone {
            if contact.phoneNumbers.isEmpty {
                contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phoneNum))]
            } else {
                contact.phoneNumbers[0] = contact.phoneNumbers[0].settingValue(CNPhoneNumber(stringValue: phoneNum))
            }
        }

    }

    private func applyNonCommunicationMutations(to contact: CNMutableContact) throws {
        // Structured arrays (replace all when provided)
        if let json = addresses { contact.postalAddresses = try parseAddresses(json) }
        if let json = urls { contact.urlAddresses = try parseURLs(json) }
        if let json = socialProfiles { contact.socialProfiles = try parseSocialProfiles(json) }
        if let json = instantMessages { contact.instantMessageAddresses = try parseInstantMessages(json) }
        if let json = relations { contact.contactRelations = try parseRelations(json) }
        if let json = dates { contact.dates = try parseDates(json) }

        // Birthday
        if let birthdayStr = birthday {
            contact.birthday = try parseBirthday(birthdayStr)
        }

        // Notes (guarded: macOS may restrict note access via TCC)
        if let note = notes {
            if contact.isKeyAvailable(CNContactNoteKey) {
                contact.note = note
            } else {
                fputs("Warning: Cannot set notes — this binary lacks the com.apple.developer.contacts.notes entitlement, which macOS requires for Contacts note access.\n", stderr)
            }
        }
    }
}

struct DeleteContact: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a contact"
    )

    @OptionGroup var pimOptions: PIMOptions

    @Option(name: .long, help: "Contact ID to delete")
    var id: String

    func run() async throws {
        try await requestContactsAccess()
        let config = pimOptions.loadConfig()
        try checkContactsEnabled(config: config)

        let mode = contactAccessMode(config: config)

        switch mode {
        case .fullAccess:
            let predicate = CNContact.predicateForContacts(withIdentifiers: [id])
            let contacts = try contactStore.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)

            guard let existingContact = contacts.first else {
                throw CLIError.notFound("Contact not found: \(id)")
            }

            let contactInfo = contactToDict(existingContact, brief: true)
            let contact = existingContact.mutableCopy() as! CNMutableContact

            let saveRequest = CNSaveRequest()
            saveRequest.delete(contact)
            try contactStore.execute(saveRequest)

            outputJSON([
                "success": true,
                "message": "Contact deleted successfully",
                "deletedContact": contactInfo
            ])

        case .scopedContainers(let allowedIds):
            try validateScopedContactAccess(id: id, allowedIds: allowedIds)

            let request = CNContactFetchRequest(keysToFetch: keysToFetch)
            request.predicate = CNContact.predicateForContacts(withIdentifiers: [id])
            request.unifyResults = false
            request.mutableObjects = false
            var fetched: CNContact?
            try contactStore.enumerateContacts(with: request) { c, stop in
                fetched = c
                stop.pointee = true
            }
            guard let existingContact = fetched else {
                throw CLIError.notFound("Contact not found: \(id)")
            }

            let contactInfo = contactToDict(existingContact, brief: true)
            let contact = existingContact.mutableCopy() as! CNMutableContact
            let saveRequest = CNSaveRequest()
            saveRequest.delete(contact)
            try contactStore.execute(saveRequest)

            outputJSON([
                "success": true,
                "message": "Contact deleted successfully",
                "deletedContact": contactInfo
            ])
        }
    }
}

// MARK: - Config Command

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage PIM configuration",
        subcommands: [ConfigShow.self]
    )
}

struct ConfigShow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Display the resolved configuration (base + profile)"
    )

    @OptionGroup var pimOptions: PIMOptions

    func run() throws {
        let config = pimOptions.loadConfig()
        let ctx = pimOptions.outputContext
        let activeProfile = pimOptions.profile ?? ProcessInfo.processInfo.environment["APPLE_PIM_PROFILE"]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)

        pimOutput(
            [
                "success": true,
                "configPath": ConfigLoader.defaultConfigPath.path,
                "profilesDir": ConfigLoader.profilesDir.path,
                "activeProfile": activeProfile as Any,
                "config": (try? JSONSerialization.jsonObject(with: data)) ?? [:]
            ],
            text: ConfigFormatter.formatConfigShow(
                config: config,
                configPath: ConfigLoader.defaultConfigPath.path,
                profilesDir: ConfigLoader.profilesDir.path,
                activeProfile: activeProfile
            ),
            context: ctx
        )
    }
}
