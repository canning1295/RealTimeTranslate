import CoreData

/// Simple Core Data stack used to persist translation sessions and utterances.
struct PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        let model = Self.createModel()
        container = NSPersistentContainer(name: "Model", managedObjectModel: model)
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores { _, error in
            if let error {
                fatalError("Unresolved error \(error)")
            }
        }
    }

    /// Programmatically define the Core Data model.
    private static func createModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        // ConversationSession entity
        let sessionEntity = NSEntityDescription()
        sessionEntity.name = "ConversationSession"
        sessionEntity.managedObjectClassName = NSStringFromClass(ConversationSession.self)

        let sessionId = NSAttributeDescription()
        sessionId.name = "id"
        sessionId.attributeType = .UUIDAttributeType
        sessionId.isOptional = false

        let timestamp = NSAttributeDescription()
        timestamp.name = "timestamp"
        timestamp.attributeType = .dateAttributeType
        timestamp.isOptional = false

        sessionEntity.properties = [sessionId, timestamp]

        // Utterance entity
        let utteranceEntity = NSEntityDescription()
        utteranceEntity.name = "Utterance"
        utteranceEntity.managedObjectClassName = NSStringFromClass(Utterance.self)

        let utteranceId = NSAttributeDescription()
        utteranceId.name = "id"
        utteranceId.attributeType = .UUIDAttributeType
        utteranceId.isOptional = false

        let original = NSAttributeDescription()
        original.name = "original"
        original.attributeType = .stringAttributeType
        original.isOptional = false

        let translated = NSAttributeDescription()
        translated.name = "translated"
        translated.attributeType = .stringAttributeType
        translated.isOptional = false

        let audioPath = NSAttributeDescription()
        audioPath.name = "audioPath"
        audioPath.attributeType = .stringAttributeType
        audioPath.isOptional = true

        let sessionRelationship = NSRelationshipDescription()
        sessionRelationship.name = "session"
        sessionRelationship.destinationEntity = sessionEntity
        sessionRelationship.minCount = 0
        sessionRelationship.maxCount = 1
        sessionRelationship.deleteRule = .nullifyDeleteRule

        let utterancesRelationship = NSRelationshipDescription()
        utterancesRelationship.name = "utterances"
        utterancesRelationship.destinationEntity = utteranceEntity
        utterancesRelationship.minCount = 0
        utterancesRelationship.maxCount = 0 // to-many
        utterancesRelationship.deleteRule = .cascadeDeleteRule

        sessionRelationship.inverseRelationship = utterancesRelationship
        utterancesRelationship.inverseRelationship = sessionRelationship

        sessionEntity.properties += [utterancesRelationship]
        utteranceEntity.properties = [utteranceId, original, translated, audioPath, sessionRelationship]

        model.entities = [sessionEntity, utteranceEntity]
        return model
    }
}
