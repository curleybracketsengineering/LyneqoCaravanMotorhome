import Foundation
import SwiftData

struct SyncDebugEntityCounts: Equatable {
    var profiles: Int = 0
    var trips: Int = 0
    var loadedItems: Int = 0
    var libraryItems: Int = 0
    var checklistSections: Int = 0
    var checklistItems: Int = 0
    var documents: Int = 0
    var attachments: Int = 0
    var appStates: Int = 0

    var logLine: String {
        "profiles=\(profiles), trips=\(trips), loadedItems=\(loadedItems), libraryItems=\(libraryItems), checklistSections=\(checklistSections), checklistItems=\(checklistItems), documents=\(documents), attachments=\(attachments), appStates=\(appStates)"
    }

    func deltaDescription(from earlier: SyncDebugEntityCounts) -> String {
        let pairs: [(String, Int, Int)] = [
            ("VehicleProfile", earlier.profiles, profiles),
            ("Trip", earlier.trips, trips),
            ("LoadedItem", earlier.loadedItems, loadedItems),
            ("LibraryItem", earlier.libraryItems, libraryItems),
            ("ChecklistSection", earlier.checklistSections, checklistSections),
            ("ChecklistItem", earlier.checklistItems, checklistItems),
            ("DocumentRecord", earlier.documents, documents),
            ("MaintenanceAttachment", earlier.attachments, attachments),
            ("AppState", earlier.appStates, appStates),
        ]
        let changed = pairs.filter { $0.1 != $0.2 }
        if changed.isEmpty { return "no count changes" }
        return changed.map { "\($0.0): \($0.1) -> \($0.2)" }.joined(separator: "\n")
    }

    static func fetch(from context: ModelContext) -> SyncDebugEntityCounts {
        SyncDebugEntityCounts(
            profiles: fetchCount(FetchDescriptor<VehicleProfile>(), from: context),
            trips: fetchCount(FetchDescriptor<Trip>(), from: context),
            loadedItems: fetchCount(FetchDescriptor<LoadedItem>(), from: context),
            libraryItems: fetchCount(FetchDescriptor<LibraryItem>(), from: context),
            checklistSections: fetchCount(FetchDescriptor<ChecklistSection>(), from: context),
            checklistItems: fetchCount(FetchDescriptor<ChecklistItem>(), from: context),
            documents: fetchCount(FetchDescriptor<DocumentRecord>(), from: context),
            attachments: fetchCount(FetchDescriptor<MaintenanceAttachment>(), from: context),
            appStates: fetchCount(FetchDescriptor<AppState>(), from: context)
        )
    }

    private static func fetchCount<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>,
        from context: ModelContext
    ) -> Int {
        (try? context.fetch(descriptor).count) ?? 0
    }
}

enum SyncDebugSeedIsolation {
    static let defaultsKey = "syncDebugSuppressAutomaticSeeding"

    #if DEBUG
    static var overrideForTests: Bool?
    #endif

    static var isAutomaticSeedingSuppressed: Bool {
        #if DEBUG
        if let overrideForTests { return overrideForTests }
        return UserDefaults.standard.bool(forKey: defaultsKey)
        #else
        return false
        #endif
    }

    static func setAutomaticSeedingSuppressed(_ value: Bool) {
        #if DEBUG
        UserDefaults.standard.set(value, forKey: defaultsKey)
        SyncDebugLogger.shared.record(
            category: "seed",
            message: "[seed] Developer isolation flag set to \(value ? "ON" : "OFF"). Release behaviour is unchanged."
        )
        #endif
    }
}

enum SyncDebugSeedLog {
    static func record(_ message: String) {
        SyncDebugLogger.shared.record(category: "seed", message: message)
    }
}

enum CloudKitModelAudit {
    static func report(schema: Schema = LoadMateModelContainer.schema) -> String {
        var lines: [String] = [
            "SwiftData CloudKit model audit",
            "Models in CloudKit-backed ModelContainer: \(schema.entities.count)",
            "",
        ]
        var flags: [String] = []

        for entity in schema.entities.sorted(by: { $0.name < $1.name }) {
            lines.append("Model name: \(entity.name)")

            let attributes = entity.attributes.sorted { $0.name < $1.name }
            if attributes.isEmpty {
                lines.append("  Attributes: none")
            } else {
                lines.append("  Attributes:")
                for attribute in attributes {
                    let optional = attribute.isOptional ? "optional" : "non-optional"
                    let defaultPresent = attribute.defaultValue == nil ? "no default" : "default present"
                    var extras: [String] = [optional, defaultPresent]
                    if attribute.isUnique { extras.append("unique") }
                    if attribute.isTransient { extras.append("transient") }
                    if attribute.isTransformable { extras.append("transformable") }
                    if let original = CloudKitModelAudit.genuineOriginalName(
                        attribute.originalName,
                        currentName: attribute.name
                    ) {
                        extras.append("originalName=\(original)")
                    }
                    lines.append(
                        "    \(attribute.name): \(typeName(attribute.valueType)) [\(extras.joined(separator: ", "))]"
                    )

                    if !attribute.isOptional, attribute.defaultValue == nil {
                        flags.append("\(entity.name).\(attribute.name): non-optional property without detectable default")
                    }
                    if attribute.isUnique {
                        flags.append("\(entity.name).\(attribute.name): unique constraint")
                    }
                    if attribute.isTransformable {
                        flags.append("\(entity.name).\(attribute.name): transformable / custom type")
                    }
                    if attribute.isTransient {
                        flags.append("\(entity.name).\(attribute.name): transient property")
                    }
                    if looksLikeEnumOrCustomType(attribute.valueType) {
                        flags.append("\(entity.name).\(attribute.name): enum or custom type \(typeName(attribute.valueType))")
                    }
                    if let original = CloudKitModelAudit.genuineOriginalName(
                        attribute.originalName,
                        currentName: attribute.name
                    ) {
                        flags.append("\(entity.name).\(attribute.name): renamed from \(original)")
                    }
                }
            }

            let relationships = entity.relationships.sorted { $0.name < $1.name }
            if relationships.isEmpty {
                lines.append("  Relationships: none")
            } else {
                lines.append("  Relationships:")
                for relationship in relationships {
                    let cardinality = relationship.isToOneRelationship ? "to-one" : "to-many"
                    let optional = relationship.isOptional ? "optional" : "non-optional"
                    let inverse = relationship.inverseName ?? "NONE"
                    var extras: [String] = [cardinality, optional, "deleteRule=\(relationship.deleteRule.rawValue)"]
                    if relationship.isUnique { extras.append("unique") }
                    if let min = relationship.minimumModelCount { extras.append("min=\(min)") }
                    if let max = relationship.maximumModelCount { extras.append("max=\(max)") }
                    lines.append(
                        "    \(relationship.name) -> \(relationship.destination) inverse=\(inverse) [\(extras.joined(separator: ", "))]"
                    )

                    if !relationship.isOptional, relationship.isToOneRelationship {
                        flags.append("\(entity.name).\(relationship.name): non-optional to-one relationship")
                    }
                    if relationship.inverseName == nil {
                        flags.append("\(entity.name).\(relationship.name): relationship without clear inverse")
                    }
                    if relationship.isUnique {
                        flags.append("\(entity.name).\(relationship.name): unique relationship constraint")
                    }
                }
            }

            if entity.uniquenessConstraints.isEmpty {
                lines.append("  Unique attributes: none")
            } else {
                let unique = entity.uniquenessConstraints.map { $0.joined(separator: "+") }.joined(separator: "; ")
                lines.append("  Unique attributes: \(unique)")
                flags.append("\(entity.name): uniquenessConstraints \(unique)")
            }
            lines.append("")
        }

        lines.append("CloudKit-sensitive flags")
        if flags.isEmpty {
            lines.append("  none detected from schema metadata")
        } else {
            for flag in flags.sorted() {
                lines.append("  - \(flag)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func genuineOriginalName(_ originalName: String, currentName: String) -> String? {
        let trimmed = originalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentName else { return nil }
        return trimmed
    }

    static func isGenuineRename(originalName: String, currentName: String) -> Bool {
        genuineOriginalName(originalName, currentName: currentName) != nil
    }

    private static func typeName(_ type: Any.Type) -> String {
        String(describing: type)
    }

    private static func looksLikeEnumOrCustomType(_ type: Any.Type) -> Bool {
        let name = typeName(type)
            .replacingOccurrences(of: "Optional<", with: "")
            .replacingOccurrences(of: ">", with: "")
        let builtins: Set<String> = [
            "String", "Int", "Int16", "Int32", "Int64", "Double", "Float",
            "Bool", "Date", "UUID", "Data", "URL", "Decimal",
        ]
        if builtins.contains(name) { return false }
        if name.hasPrefix("Array<") || name.hasPrefix("[") { return false }
        return true
    }
}
