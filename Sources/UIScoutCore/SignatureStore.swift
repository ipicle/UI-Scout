import Foundation
import GRDB
import Logging

public class SignatureStore {
    private let dbQueue: DatabaseQueue
    private let logger = Logger(label: "ui-scout.signature-store")
    
    public init(databasePath: String? = nil) throws {
        let path = databasePath ?? Self.defaultDatabasePath()
        
        // Ensure directory exists
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        
        dbQueue = try DatabaseQueue(path: path)
        try setupDatabase()
    }
    
    private static func defaultDatabasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let uiScoutDir = appSupport.appendingPathComponent("UIScout")
        try? FileManager.default.createDirectory(at: uiScoutDir, withIntermediateDirectories: true)
        return uiScoutDir.appendingPathComponent("signatures.db").path
    }
    
    // MARK: - Database Setup
    
    private func setupDatabase() throws {
        try dbQueue.write { db in
            // First, migrate any legacy camelCase schemas to snake_case
            try migrateLegacySchemasIfNeeded(db)

            // Signatures table
            try db.create(table: "signatures", ifNotExists: true) { table in
                table.column("id", .text).primaryKey()
                table.column("app_bundle_id", .text).notNull()
                table.column("element_type", .text).notNull()
                table.column("role", .text).notNull()
                table.column("subroles", .text) // JSON array
                table.column("frame_hash", .text).notNull()
                table.column("path_hint", .text) // JSON array
                table.column("sibling_roles", .text) // JSON array
                table.column("read_only", .boolean).notNull()
                table.column("scrollable", .boolean).notNull()
                table.column("attrs", .text) // JSON object
                table.column("stability", .double).notNull()
                table.column("last_verified_at", .double).notNull()
                table.column("is_pinned", .boolean).notNull().defaults(to: false)
                table.column("created_at", .double).notNull()
                table.column("updated_at", .double).notNull()
            }
            
            // Evidence table
            try db.create(table: "evidence", ifNotExists: true) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("signature_id", .text).notNull()
                table.column("method", .text).notNull()
                table.column("heuristic_score", .double).notNull()
                table.column("diff_score", .double).notNull()
                table.column("ocr_change", .boolean).notNull()
                table.column("notifications", .text) // JSON array
                table.column("confidence", .double).notNull()
                table.column("timestamp", .double).notNull()
                
                table.foreignKey(["signature_id"], references: "signatures", columns: ["id"], onDelete: .cascade)
            }
            
            // History table for behavioral patterns
            try db.create(table: "behavioral_history", ifNotExists: true) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("signature_id", .text).notNull()
                table.column("action", .text).notNull() // "send", "focus", "select"
                table.column("before_snapshot", .text) // JSON
                table.column("after_snapshot", .text) // JSON
                table.column("success", .boolean).notNull()
                table.column("timestamp", .double).notNull()
                
                table.foreignKey(["signature_id"], references: "signatures", columns: ["id"], onDelete: .cascade)
            }
            
            // Indexes for performance - handle existing indexes gracefully
            do {
                try db.create(index: "idx_signatures_app_type", on: "signatures", columns: ["app_bundle_id", "element_type"], ifNotExists: true)
            } catch {
                // Index already exists, ignore
            }
            
            do {
                try db.create(index: "idx_signatures_stability", on: "signatures", columns: ["stability"], ifNotExists: true)
            } catch {
                // Index already exists, ignore
            }
            
            do {
                try db.create(index: "idx_evidence_signature", on: "evidence", columns: ["signature_id", "timestamp"], ifNotExists: true)
            } catch {
                // Index already exists, ignore
            }
            
            do {
                try db.create(index: "idx_history_signature", on: "behavioral_history", columns: ["signature_id", "timestamp"], ifNotExists: true)
            } catch {
                // Index already exists, ignore
            }
        }
    }

    // MARK: - Migrations

    private func columnNames(in table: String, db: Database) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        let names: [String] = rows.compactMap { row in
            // PRAGMA table_info returns columns: cid, name, type, notnull, dflt_value, pk
            return row["name"]
        }
        return Set(names)
    }

    private func migrateLegacySchemasIfNeeded(_ db: Database) throws {
        // Signatures: look for camelCase like appBundleId
        if try db.tableExists("signatures") {
            let cols = try columnNames(in: "signatures", db: db)
            if cols.contains("appBundleId") { // legacy schema detected
                try db.execute(sql: """
                    CREATE TABLE signatures_new (
                        id TEXT PRIMARY KEY,
                        app_bundle_id TEXT NOT NULL,
                        element_type TEXT NOT NULL,
                        role TEXT NOT NULL,
                        subroles TEXT,
                        frame_hash TEXT NOT NULL,
                        path_hint TEXT,
                        sibling_roles TEXT,
                        read_only BOOLEAN NOT NULL,
                        scrollable BOOLEAN NOT NULL,
                        attrs TEXT,
                        stability DOUBLE NOT NULL,
                        last_verified_at DOUBLE NOT NULL,
                        is_pinned BOOLEAN NOT NULL DEFAULT 0,
                        created_at DOUBLE NOT NULL,
                        updated_at DOUBLE NOT NULL
                    )
                """)
                try db.execute(sql: """
                    INSERT INTO signatures_new (
                        id, app_bundle_id, element_type, role, subroles, frame_hash, path_hint, sibling_roles,
                        read_only, scrollable, attrs, stability, last_verified_at, is_pinned, created_at, updated_at
                    )
                    SELECT
                        id, appBundleId, elementType, role, subroles, frameHash, pathHint, siblingRoles,
                        readOnly, scrollable, attrs, stability, lastVerifiedAt, isPinned, createdAt, updatedAt
                    FROM signatures
                """)
                try db.execute(sql: "DROP TABLE signatures")
                try db.execute(sql: "ALTER TABLE signatures_new RENAME TO signatures")
            }
        }

        // Evidence: look for signatureId
        if try db.tableExists("evidence") {
            let cols = try columnNames(in: "evidence", db: db)
            if cols.contains("signatureId") { // legacy schema detected
                try db.execute(sql: """
                    CREATE TABLE evidence_new (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        signature_id TEXT NOT NULL,
                        method TEXT NOT NULL,
                        heuristic_score DOUBLE NOT NULL,
                        diff_score DOUBLE NOT NULL,
                        ocr_change BOOLEAN NOT NULL,
                        notifications TEXT,
                        confidence DOUBLE NOT NULL,
                        timestamp DOUBLE NOT NULL
                    )
                """)
                try db.execute(sql: """
                    INSERT INTO evidence_new (
                        id, signature_id, method, heuristic_score, diff_score, ocr_change, notifications, confidence, timestamp
                    )
                    SELECT id, signatureId, method, heuristicScore, diffScore, ocrChange, notifications, confidence, timestamp
                    FROM evidence
                """)
                try db.execute(sql: "DROP TABLE evidence")
                try db.execute(sql: "ALTER TABLE evidence_new RENAME TO evidence")
            }
        }

        // Behavioral history: look for signatureId/beforeSnapshot/afterSnapshot
        if try db.tableExists("behavioral_history") {
            let cols = try columnNames(in: "behavioral_history", db: db)
            if cols.contains("signatureId") || cols.contains("beforeSnapshot") || cols.contains("afterSnapshot") {
                try db.execute(sql: """
                    CREATE TABLE behavioral_history_new (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        signature_id TEXT NOT NULL,
                        action TEXT NOT NULL,
                        before_snapshot TEXT,
                        after_snapshot TEXT,
                        success BOOLEAN NOT NULL,
                        timestamp DOUBLE NOT NULL
                    )
                """)
                // Handle possibly missing legacy columns with COALESCE to null-safe
                let beforeExpr = cols.contains("beforeSnapshot") ? "beforeSnapshot" : "before_snapshot"
                let afterExpr = cols.contains("afterSnapshot") ? "afterSnapshot" : "after_snapshot"
                let sigExpr = cols.contains("signatureId") ? "signatureId" : "signature_id"
                try db.execute(sql: """
                    INSERT INTO behavioral_history_new (
                        id, signature_id, action, before_snapshot, after_snapshot, success, timestamp
                    )
                    SELECT id, \(sigExpr), action, \(beforeExpr), \(afterExpr), success, timestamp
                    FROM behavioral_history
                """)
                try db.execute(sql: "DROP TABLE behavioral_history")
                try db.execute(sql: "ALTER TABLE behavioral_history_new RENAME TO behavioral_history")
            }
        }
    }
    
    // MARK: - Signature CRUD
    
    public func storeSignature(_ signature: ElementSignature) async {
        do {
            try await dbQueue.write { [weak self] db in
                var signatureRecord = try SignatureRecord(from: signature)
                try signatureRecord.save(db)
                self?.logger.debug("Stored signature \(signatureRecord.id)")
            }
        } catch {
            logger.error("Failed to store signature: \(error)")
        }
    }
    
    public func updateSignature(_ signature: ElementSignature) async {
        do {
            try await dbQueue.write { [weak self] db in
                var signatureRecord = try SignatureRecord(from: signature)
                signatureRecord.updatedAt = Date().timeIntervalSince1970
                try signatureRecord.update(db)
                self?.logger.debug("Updated signature \(signatureRecord.id)")
            }
        } catch {
            logger.error("Failed to update signature: \(error)")
        }
    }
    
    public func getBestSignature(
        appBundleId: String,
        elementType: ElementSignature.ElementType
    ) async -> ElementSignature? {
        do {
            return try await dbQueue.read { db in
                if let record = try SignatureRecord
                    .filter(Column("app_bundle_id") == appBundleId)
                    .filter(Column("element_type") == elementType.rawValue)
                    .order(Column("stability").desc, Column("last_verified_at").desc)
                    .fetchOne(db) {
                    return try record.toElementSignature()
                }
                return nil
            }
        } catch {
            logger.error("Failed to get best signature: \(error)")
            return nil
        }
    }
    
    public func getAllSignatures(
        appBundleId: String? = nil,
        elementType: ElementSignature.ElementType? = nil
    ) async -> [ElementSignature] {
        do {
            return try await dbQueue.read { db in
                var request = SignatureRecord.all()
                
                if let bundleId = appBundleId {
                    request = request.filter(Column("app_bundle_id") == bundleId)
                }
                
                if let type = elementType {
                    request = request.filter(Column("element_type") == type.rawValue)
                }
                
                let records = try request.order(Column("stability").desc).fetchAll(db)
                return records.compactMap { try? $0.toElementSignature() }
            }
        } catch {
            logger.error("Failed to get signatures: \(error)")
            return []
        }
    }
    
    public func pinSignature(_ signature: ElementSignature) async {
        do {
        try await dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE signatures SET is_pinned = true WHERE id = ?",
            arguments: [self.generateSignatureId(signature)]
                )
            }
        } catch {
            logger.error("Failed to pin signature: \(error)")
        }
    }
    
    public func decaySignature(_ signature: ElementSignature) async {
        let decayFactor = 0.8
        let newStability = signature.stability * decayFactor
        
        var updatedSignature = signature
        updatedSignature.stability = newStability
        
        await updateSignature(updatedSignature)
    }
    
    public func removeSignature(_ signature: ElementSignature) async {
        do {
        try await dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM signatures WHERE id = ?",
            arguments: [self.generateSignatureId(signature)]
                )
            }
        } catch {
            logger.error("Failed to remove signature: \(error)")
        }
    }
    
    // MARK: - Evidence Management
    
    public func recordEvidence(_ evidence: Evidence, for signature: ElementSignature) async {
        do {
        try await dbQueue.write { [weak self] db in
                var evidenceRecord = EvidenceRecord(
            signatureId: self?.generateSignatureId(signature) ?? "",
                    evidence: evidence
                )
                try evidenceRecord.save(db)
                self?.logger.debug("Recorded evidence for signature")
            }
        } catch {
            logger.error("Failed to record evidence: \(error)")
        }
    }
    
    public func getRecentEvidence(
        for signature: ElementSignature,
        limit: Int = 10
    ) async -> [Evidence] {
        do {
        return try await dbQueue.read { db in
                let records = try EvidenceRecord
            .filter(Column("signature_id") == self.generateSignatureId(signature))
                    .order(Column("timestamp").desc)
                    .limit(limit)
                    .fetchAll(db)
                
                return records.map { $0.toEvidence() }
            }
        } catch {
            logger.error("Failed to get recent evidence: \(error)")
            return []
        }
    }
    
    // MARK: - Behavioral History
    
    public func recordBehavior(
        signature: ElementSignature,
        action: String,
        beforeSnapshot: ElementSnapshot?,
        afterSnapshot: ElementSnapshot?,
        success: Bool
    ) async {
        do {
        try await dbQueue.write { db in
                var historyRecord = BehavioralHistoryRecord(
            signatureId: self.generateSignatureId(signature),
                    action: action,
                    beforeSnapshot: beforeSnapshot,
                    afterSnapshot: afterSnapshot,
                    success: success,
                    timestamp: Date().timeIntervalSince1970
                )
                try historyRecord.save(db)
            }
        } catch {
            logger.error("Failed to record behavioral history: \(error)")
        }
    }
    
    private func getBehavioralHistory(
        for signature: ElementSignature,
        limit: Int = 20
    ) async -> [BehavioralHistoryRecord] {
        do {
            return try await dbQueue.read { db in
                try BehavioralHistoryRecord
                    .filter(Column("signature_id") == self.generateSignatureId(signature))
                    .order(Column("timestamp").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            logger.error("Failed to get behavioral history: \(error)")
            return []
        }
    }
    
    // MARK: - Cleanup and Maintenance
    
    public func cleanupOldData(olderThanDays: Int = 30) async {
        let cutoff = Date().timeIntervalSince1970 - TimeInterval(olderThanDays * 24 * 3600)
        
        do {
            try await dbQueue.write { db in
                // Clean old evidence
                try db.execute(
                    sql: "DELETE FROM evidence WHERE timestamp < ?",
                    arguments: [cutoff]
                )
                
                // Clean old behavioral history
                try db.execute(
                    sql: "DELETE FROM behavioral_history WHERE timestamp < ?",
                    arguments: [cutoff]
                )
                
                // Clean unpinned signatures that haven't been verified recently
                try db.execute(
                    sql: "DELETE FROM signatures WHERE is_pinned = false AND last_verified_at < ? AND stability < 0.5",
                    arguments: [cutoff]
                )
            }
        } catch {
            logger.error("Failed to cleanup old data: \(error)")
        }
    }
    
    public func getStatistics() async -> StoreStatistics {
        do {
            return try await dbQueue.read { db in
                let signatureCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM signatures"
                ) ?? 0
                
                let evidenceCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM evidence"
                ) ?? 0
                
                let avgStability = try Double.fetchOne(
                    db,
                    sql: "SELECT AVG(stability) FROM signatures"
                ) ?? 0.0
                
                let pinnedCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM signatures WHERE is_pinned = true"
                ) ?? 0
                
                return StoreStatistics(
                    signatureCount: signatureCount,
                    evidenceCount: evidenceCount,
                    averageStability: avgStability,
                    pinnedSignatureCount: pinnedCount
                )
            }
        } catch {
            logger.error("Failed to get statistics: \(error)")
            return StoreStatistics(signatureCount: 0, evidenceCount: 0, averageStability: 0.0, pinnedSignatureCount: 0)
        }
    }
    
    // MARK: - Helper Methods
    
    private func generateSignatureId(_ signature: ElementSignature) -> String {
        return "\(signature.appBundleId)-\(signature.elementType.rawValue)-\(signature.frameHash)"
    }
}

// MARK: - Database Records

private struct SignatureRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var appBundleId: String
    var elementType: String
    var role: String
    var subroles: String
    var frameHash: String
    var pathHint: String
    var siblingRoles: String
    var readOnly: Bool
    var scrollable: Bool
    var attrs: String
    var stability: Double
    var lastVerifiedAt: Double
    var isPinned: Bool
    var createdAt: Double
    var updatedAt: Double
    
    static let databaseTableName = "signatures"
    
    init(from signature: ElementSignature) throws {
        let encoder = JSONEncoder()
        
        self.id = "\(signature.appBundleId)-\(signature.elementType.rawValue)-\(signature.frameHash)"
        self.appBundleId = signature.appBundleId
        self.elementType = signature.elementType.rawValue
        self.role = signature.role
        self.subroles = String(data: try encoder.encode(signature.subroles), encoding: .utf8) ?? "[]"
        self.frameHash = signature.frameHash
        self.pathHint = String(data: try encoder.encode(signature.pathHint), encoding: .utf8) ?? "[]"
        self.siblingRoles = String(data: try encoder.encode(signature.siblingRoles), encoding: .utf8) ?? "[]"
        self.readOnly = signature.readOnly
        self.scrollable = signature.scrollable
        self.attrs = String(data: try encoder.encode(signature.attrs), encoding: .utf8) ?? "{}"
        self.stability = signature.stability
        self.lastVerifiedAt = signature.lastVerifiedAt
        self.isPinned = false
        self.createdAt = Date().timeIntervalSince1970
        self.updatedAt = Date().timeIntervalSince1970
    }

    // Decode from database row (snake_case columns)
    init(row: Row) throws {
        self.id = row["id"]
        self.appBundleId = row["app_bundle_id"]
        self.elementType = row["element_type"]
        self.role = row["role"]
        self.subroles = row["subroles"]
        self.frameHash = row["frame_hash"]
        self.pathHint = row["path_hint"]
        self.siblingRoles = row["sibling_roles"]
        self.readOnly = row["read_only"]
        self.scrollable = row["scrollable"]
        self.attrs = row["attrs"]
        self.stability = row["stability"]
        self.lastVerifiedAt = row["last_verified_at"]
        self.isPinned = row["is_pinned"]
        self.createdAt = row["created_at"]
        self.updatedAt = row["updated_at"]
    }

    // Ensure proper snake_case column mapping on insert/update
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["app_bundle_id"] = appBundleId
        container["element_type"] = elementType
        container["role"] = role
        container["subroles"] = subroles
        container["frame_hash"] = frameHash
        container["path_hint"] = pathHint
        container["sibling_roles"] = siblingRoles
        container["read_only"] = readOnly
        container["scrollable"] = scrollable
        container["attrs"] = attrs
        container["stability"] = stability
        container["last_verified_at"] = lastVerifiedAt
        container["is_pinned"] = isPinned
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
    }
    
    func toElementSignature() throws -> ElementSignature {
        let decoder = JSONDecoder()
        
        guard let elementType = ElementSignature.ElementType(rawValue: self.elementType) else {
            throw StoreError.invalidElementType(self.elementType)
        }
        
        let subroles = try decoder.decode([String].self, from: Data(self.subroles.utf8))
        let pathHint = try decoder.decode([String].self, from: Data(self.pathHint.utf8))
        let siblingRoles = try decoder.decode([String].self, from: Data(self.siblingRoles.utf8))
        let attrs = try decoder.decode([String: ElementSignature.AttributeValue?].self, from: Data(self.attrs.utf8))
        
        return ElementSignature(
            appBundleId: appBundleId,
            elementType: elementType,
            role: role,
            subroles: subroles,
            frameHash: frameHash,
            pathHint: pathHint,
            siblingRoles: siblingRoles,
            readOnly: readOnly,
            scrollable: scrollable,
            attrs: attrs,
            stability: stability,
            lastVerifiedAt: lastVerifiedAt
        )
    }
    
    // MARK: - GRDB Column Mapping
    
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let appBundleId = Column("app_bundle_id")
        static let elementType = Column("element_type")
        static let role = Column(CodingKeys.role)
        static let subroles = Column(CodingKeys.subroles)
        static let frameHash = Column("frame_hash")
        static let pathHint = Column("path_hint")
        static let siblingRoles = Column("sibling_roles")
        static let readOnly = Column("read_only")
        static let scrollable = Column(CodingKeys.scrollable)
        static let attrs = Column(CodingKeys.attrs)
        static let stability = Column(CodingKeys.stability)
        static let lastVerifiedAt = Column("last_verified_at")
        static let isPinned = Column("is_pinned")
        static let createdAt = Column("created_at")
        static let updatedAt = Column("updated_at")
    }
}

private struct EvidenceRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var signatureId: String
    var method: String
    var heuristicScore: Double
    var diffScore: Double
    var ocrChange: Bool
    var notifications: String
    var confidence: Double
    var timestamp: Double
    
    static let databaseTableName = "evidence"
    
    init(signatureId: String, evidence: Evidence) {
        self.signatureId = signatureId
        self.method = evidence.method.rawValue
        self.heuristicScore = evidence.heuristicScore
        self.diffScore = evidence.diffScore
        self.ocrChange = evidence.ocrChange
        self.notifications = (try? String(data: JSONEncoder().encode(evidence.notifications), encoding: .utf8)) ?? "[]"
        self.confidence = evidence.confidence
        self.timestamp = evidence.timestamp
    }

    // Decode from database row (snake_case columns)
    init(row: Row) {
        self.id = row["id"]
        self.signatureId = row["signature_id"]
        self.method = row["method"]
        self.heuristicScore = row["heuristic_score"]
        self.diffScore = row["diff_score"]
        self.ocrChange = row["ocr_change"]
        self.notifications = row["notifications"]
        self.confidence = row["confidence"]
        self.timestamp = row["timestamp"]
    }

    // Ensure proper snake_case column mapping on insert/update
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["signature_id"] = signatureId
        container["method"] = method
        container["heuristic_score"] = heuristicScore
        container["diff_score"] = diffScore
        container["ocr_change"] = ocrChange
        container["notifications"] = notifications
        container["confidence"] = confidence
        container["timestamp"] = timestamp
    }
    
    func toEvidence() -> Evidence {
        let decoder = JSONDecoder()
        let notifications = (try? decoder.decode([String].self, from: Data(self.notifications.utf8))) ?? []
        let method = Evidence.DetectionMethod(rawValue: self.method) ?? .passive
        
        return Evidence(
            method: method,
            heuristicScore: heuristicScore,
            diffScore: diffScore,
            ocrChange: ocrChange,
            notifications: notifications,
            confidence: confidence,
            timestamp: timestamp
        )
    }
    
    // MARK: - GRDB Column Mapping
    
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let signatureId = Column("signature_id")
        static let method = Column(CodingKeys.method)
        static let heuristicScore = Column("heuristic_score")
        static let diffScore = Column("diff_score")
        static let ocrChange = Column("ocr_change")
        static let notifications = Column(CodingKeys.notifications)
        static let confidence = Column(CodingKeys.confidence)
        static let timestamp = Column(CodingKeys.timestamp)
    }
}

private struct BehavioralHistoryRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var signatureId: String
    var action: String
    var beforeSnapshot: String?
    var afterSnapshot: String?
    var success: Bool
    var timestamp: Double
    
    static let databaseTableName = "behavioral_history"
    
    init(
        signatureId: String,
        action: String,
        beforeSnapshot: ElementSnapshot?,
        afterSnapshot: ElementSnapshot?,
        success: Bool,
        timestamp: Double
    ) {
        self.signatureId = signatureId
        self.action = action
        self.beforeSnapshot = beforeSnapshot?.jsonString()
        self.afterSnapshot = afterSnapshot?.jsonString()
        self.success = success
        self.timestamp = timestamp
    }

    // Decode from database row (snake_case columns)
    init(row: Row) {
        self.id = row["id"]
        self.signatureId = row["signature_id"]
        self.action = row["action"]
        self.beforeSnapshot = row["before_snapshot"]
        self.afterSnapshot = row["after_snapshot"]
        self.success = row["success"]
        self.timestamp = row["timestamp"]
    }

    // Ensure proper snake_case column mapping on insert/update
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["signature_id"] = signatureId
        container["action"] = action
        container["before_snapshot"] = beforeSnapshot
        container["after_snapshot"] = afterSnapshot
        container["success"] = success
        container["timestamp"] = timestamp
    }
    
    // MARK: - GRDB Column Mapping
    
    enum Columns {
        static let id = Column(CodingKeys.id)
        static let signatureId = Column("signature_id")
        static let action = Column(CodingKeys.action)
        static let beforeSnapshot = Column("before_snapshot")
        static let afterSnapshot = Column("after_snapshot")
        static let success = Column(CodingKeys.success)
        static let timestamp = Column(CodingKeys.timestamp)
    }
}

// MARK: - Store Statistics

public struct StoreStatistics: Codable {
    public let signatureCount: Int
    public let evidenceCount: Int
    public let averageStability: Double
    public let pinnedSignatureCount: Int
    
    public var description: String {
        return """
        Store Statistics:
        - Signatures: \(signatureCount) (\(pinnedSignatureCount) pinned)
        - Evidence records: \(evidenceCount)
        - Average stability: \(String(format: "%.2f", averageStability))
        """
    }
}

// MARK: - Store Errors

public enum StoreError: Error {
    case invalidElementType(String)
    case serializationError(String)
    case databaseError(Error)
}

// MARK: - Extensions

extension ElementSnapshot {
    fileprivate func jsonString() -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
