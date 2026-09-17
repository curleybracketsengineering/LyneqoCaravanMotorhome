import Foundation
import SwiftData

enum DocumentStore {
    @discardableResult
    static func createRecord(for vehicleID: UUID, in context: ModelContext) -> DocumentRecord {
        let record = DocumentRecord(vehicleID: vehicleID)
        context.insert(record)
        _ = SyncDebugSaveHelper.save(context, source: "DocumentStore.createRecord")
        return record
    }

    static func save(
        record: DocumentRecord,
        title: String,
        category: DocumentCategory,
        dateAdded: Date,
        expiryDate: Date?,
        reminderDate: Date?,
        notes: String,
        isWarrantyRelated: Bool = false,
        in context: ModelContext
    ) {
        record.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        record.category = category
        record.dateAdded = dateAdded
        record.expiryDate = expiryDate
        record.reminderDate = reminderDate
        record.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        record.isWarrantyRelated = isWarrantyRelated
            || WarrantySupport.warrantyDocumentCategories.contains(category)
        record.updatedAt = Date()
        _ = SyncDebugSaveHelper.save(context, source: "DocumentStore.save")
    }
}
