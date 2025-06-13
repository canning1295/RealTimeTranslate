import CoreData

@objc(ConversationSession)
class ConversationSession: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var timestamp: Date
    @NSManaged var utterances: Set<Utterance>
}

@objc(Utterance)
class Utterance: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var original: String
    @NSManaged var translated: String
    @NSManaged var audioPath: String?
    @NSManaged var session: ConversationSession
}
