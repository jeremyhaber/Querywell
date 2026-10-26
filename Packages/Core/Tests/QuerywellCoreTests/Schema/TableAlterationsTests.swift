import Foundation
import Testing

@testable import QuerywellCore

private let my = SQLDialect(.mysql)
private let pg = SQLDialect(.postgresql)
private let table = TableRef(schema: "shop", name: "orders")

private func structure(
    _ ref: TableRef = table, kind: TableKind = .table, columns: [ColumnDefinition] = [], fks: [ForeignKeyDefinition] = []
) -> TableStructure {
    TableStructure(info: TableInfo(ref: ref, kind: kind), columns: columns, indexes: [], foreignKeys: fks, referencedBy: [])
}

@Suite("Table alterations: rename and move")
struct RenameMoveTests {
    @Test func renameQuotesBothDialects() throws {
        #expect(try TableAlterations.rename(table, to: "o`2", dialect: my).statements == ["RENAME TABLE `shop`.`orders` TO `shop`.`o``2`"])
        #expect(try TableAlterations.rename(table, to: "o\"2", dialect: pg).statements == ["ALTER TABLE \"shop\".\"orders\" RENAME TO \"o\"\"2\""])
    }

    @Test func renameRejectsEmptyAndSameName() {
        #expect(throws: TableAlterationError.noChange) { try TableAlterations.rename(table, to: "orders", dialect: my) }
        #expect(throws: TableAlterationError.self) { try TableAlterations.rename(table, to: "  ", dialect: pg) }
    }

    @Test func moveAcrossDatabasesMySQL() throws {
        let plan = try TableAlterations.move(table, to: TableRef(schema: "arch`ive", name: "orders"), dialect: my)
        #expect(plan.statements == ["RENAME TABLE `shop`.`orders` TO `arch``ive`.`orders`"])
    }

    @Test func moveWithRenamePostgresIsTwoStatements() throws {
        let plan = try TableAlterations.move(table, to: TableRef(schema: "archive", name: "old_orders"), dialect: pg)
        #expect(plan.statements == [
            "ALTER TABLE \"shop\".\"orders\" SET SCHEMA \"archive\"",
            "ALTER TABLE \"archive\".\"orders\" RENAME TO \"old_orders\"",
        ])
        let onlySchema = try TableAlterations.move(table, to: TableRef(schema: "archive", name: "orders"), dialect: pg)
        #expect(onlySchema.statements.count == 1)
        #expect(throws: TableAlterationError.noChange) { try TableAlterations.move(table, to: table, dialect: pg) }
    }
}

@Suite("Table alterations: options")
struct OptionsTests {
    private let current = TableOptions(engine: "InnoDB", collation: "utf8mb4_general_ci", comment: "old", autoIncrement: 10, rowFormat: "Dynamic")

    @Test func mysqlCombinesChangedOptionsOnly() throws {
        let changes = TableOptionChanges(
            engine: "MyISAM", collation: "utf8mb4_unicode_ci", comment: "it's new", autoIncrement: 500, rowFormat: "compact")
        let plan = try TableAlterations.options(table, current: current, changes: changes, dialect: my)
        #expect(plan.statements == [
            "ALTER TABLE `shop`.`orders` ENGINE=MyISAM, COLLATE=utf8mb4_unicode_ci, COMMENT='it\\'s new', AUTO_INCREMENT=500, ROW_FORMAT=COMPACT"
        ])
        #expect(plan.warnings.contains { $0.contains("existing columns keep") })
    }

    @Test func unchangedValuesProduceNothing() {
        let same = TableOptionChanges(engine: "innodb", collation: "utf8mb4_general_ci", comment: "old", autoIncrement: 10, rowFormat: "DYNAMIC")
        #expect(throws: TableAlterationError.noChange) { try TableAlterations.options(table, current: current, changes: same, dialect: my) }
    }

    @Test func emptyCommentClearsIt() throws {
        let plan = try TableAlterations.options(table, current: current, changes: TableOptionChanges(comment: ""), dialect: my)
        #expect(plan.statements == ["ALTER TABLE `shop`.`orders` COMMENT=''"])
        let pgPlan = try TableAlterations.options(
            table, current: TableOptions(comment: "old"), changes: TableOptionChanges(comment: ""), dialect: pg)
        #expect(pgPlan.statements == ["COMMENT ON TABLE \"shop\".\"orders\" IS NULL"])
    }

    @Test func convertColumnsUsesConvertToWithDerivedCharset() throws {
        let plan = try TableAlterations.options(
            table, current: current, changes: TableOptionChanges(collation: "latin1_swedish_ci", convertColumns: true), dialect: my)
        #expect(plan.statements == ["ALTER TABLE `shop`.`orders` CONVERT TO CHARACTER SET latin1 COLLATE latin1_swedish_ci"])
        // Converting to the table's current collation still converts the columns.
        let again = try TableAlterations.options(
            table, current: current, changes: TableOptionChanges(collation: "utf8mb4_general_ci", convertColumns: true), dialect: my)
        #expect(again.statements.count == 1)
        #expect(TableAlterations.charset(of: "binary") == "binary")
    }

    @Test func keywordPositionValuesAreValidated() {
        #expect(throws: TableAlterationError.invalidName("InnoDB; DROP TABLE x")) {
            try TableAlterations.options(table, current: current, changes: TableOptionChanges(engine: "InnoDB; DROP TABLE x"), dialect: my)
        }
        #expect(throws: TableAlterationError.invalidName("a b")) {
            try TableAlterations.options(table, current: current, changes: TableOptionChanges(rowFormat: "a b"), dialect: my)
        }
        #expect(throws: TableAlterationError.self) {
            try TableAlterations.options(table, current: current, changes: TableOptionChanges(autoIncrement: 0), dialect: my)
        }
    }

    @Test func postgresRejectsMySQLOptions() {
        #expect(throws: TableAlterationError.self) { try TableAlterations.options(table, current: .init(), changes: .init(engine: "InnoDB"), dialect: pg) }
        #expect(throws: TableAlterationError.self) { try TableAlterations.options(table, current: .init(), changes: .init(rowFormat: "DYNAMIC"), dialect: pg) }
        #expect(throws: TableAlterationError.self) { try TableAlterations.options(table, current: .init(), changes: .init(collation: "C"), dialect: pg) }
        #expect(throws: TableAlterationError.self) { try TableAlterations.options(table, current: .init(), changes: .init(tablespace: "x"), dialect: my) }
    }

    @Test func postgresRestartsTheSequence() throws {
        let current = TableOptions(autoIncrement: 5, sequence: TableRef(schema: "shop", name: "orders_id_seq"))
        let plan = try TableAlterations.options(table, current: current, changes: .init(comment: "c'q", autoIncrement: 100, tablespace: "fast"), dialect: pg)
        #expect(plan.statements == [
            "COMMENT ON TABLE \"shop\".\"orders\" IS 'c''q'",
            "ALTER TABLE \"shop\".\"orders\" SET TABLESPACE \"fast\"",
            "ALTER SEQUENCE \"shop\".\"orders_id_seq\" RESTART WITH 100",
        ])
        #expect(throws: TableAlterationError.self) {
            try TableAlterations.options(table, current: TableOptions(), changes: .init(autoIncrement: 3), dialect: pg)
        }
    }

    @Test func autoIncrementIsParsedFromTheCreateStatementTail() {
        let ddl = "CREATE TABLE `t` (\n  `id` int NOT NULL AUTO_INCREMENT,\n  PRIMARY KEY (`id`)\n) ENGINE=InnoDB AUTO_INCREMENT=42 DEFAULT CHARSET=utf8mb4 COMMENT='AUTO_INCREMENT=7'"
        #expect(MySQLSchemaInspector.parseAutoIncrement(createStatement: ddl) == 42)
        #expect(MySQLSchemaInspector.parseAutoIncrement(createStatement: "CREATE TABLE t (id int) ENGINE=InnoDB") == nil)
        #expect(MySQLSchemaInspector.parseAutoIncrement(createStatement: "CREATE TABLE t (id int) COMMENT='AUTO_INCREMENT=7'") == nil)
    }
}

@Suite("Table alterations: copy")
struct CopyTests {
    private let target = TableRef(schema: "archive", name: "orders_copy")
    private let fk = ForeignKeyDefinition(
        name: "fk_user", columns: ["user_id"], referenced: TableRef(schema: "shop", name: "users"), referencedColumns: ["id"],
        onUpdate: "NO ACTION", onDelete: "CASCADE", table: table)

    @Test func mysqlStructureAndDataAcrossDatabases() throws {
        let plan = try TableAlterations.copy(
            structure(fks: [fk]), to: target,
            options: CopyOptions(mode: .structureAndData, dropTargetFirst: true, keepAutoIncrement: true, addConstraints: true),
            autoIncrement: 77, dialect: my)
        #expect(plan.statements == [
            "DROP TABLE IF EXISTS `archive`.`orders_copy`",
            "CREATE TABLE `archive`.`orders_copy` LIKE `shop`.`orders`",
            "INSERT INTO `archive`.`orders_copy` SELECT * FROM `shop`.`orders`",
            "ALTER TABLE `archive`.`orders_copy` ADD FOREIGN KEY (`user_id`) REFERENCES `shop`.`users` (`id`) ON DELETE CASCADE",
            "ALTER TABLE `archive`.`orders_copy` AUTO_INCREMENT = 77",
        ])
    }

    @Test func structureOnlyHasNoInsertAndWarnsAboutForeignKeys() throws {
        let plan = try TableAlterations.copy(structure(fks: [fk]), to: target, options: CopyOptions(mode: .structureOnly), dialect: my)
        #expect(plan.statements == ["CREATE TABLE `archive`.`orders_copy` LIKE `shop`.`orders`"])
        #expect(plan.warnings.contains { $0.contains("add constraints") })
    }

    @Test func dataOnlyIgnoresStructureOptions() throws {
        let plan = try TableAlterations.copy(
            structure(fks: [fk]), to: target,
            options: CopyOptions(mode: .dataOnly, dropTargetFirst: true, keepAutoIncrement: true, addConstraints: true), autoIncrement: 5, dialect: my)
        #expect(plan.statements == ["INSERT INTO `archive`.`orders_copy` SELECT * FROM `shop`.`orders`"])
    }

    @Test func postgresUsesLikeIncludingAllAndNamedConstraints() throws {
        let serial = ColumnDefinition(name: "id", ordinal: 1, dataType: "int4", fullType: "integer", isNullable: false,
                                      defaultExpression: "nextval('orders_id_seq'::regclass)")
        let plan = try TableAlterations.copy(
            structure(columns: [serial], fks: [fk]), to: target,
            options: CopyOptions(mode: .structureAndData, keepAutoIncrement: true, addConstraints: true), autoIncrement: 9, dialect: pg)
        #expect(plan.statements == [
            "CREATE TABLE \"archive\".\"orders_copy\" (LIKE \"shop\".\"orders\" INCLUDING ALL)",
            "INSERT INTO \"archive\".\"orders_copy\" SELECT * FROM \"shop\".\"orders\"",
            "ALTER TABLE \"archive\".\"orders_copy\" ADD CONSTRAINT \"fk_user\" FOREIGN KEY (\"user_id\") REFERENCES \"shop\".\"users\" (\"id\") ON DELETE CASCADE",
        ])
        #expect(plan.warnings.contains { $0.contains("sequence") })
    }

    @Test func selfReferencingForeignKeyPointsAtTheCopy() throws {
        let selfFK = ForeignKeyDefinition(name: "fk_parent", columns: ["parent_id"], referenced: table, referencedColumns: ["id"], onDelete: "SET NULL", table: table)
        let plan = try TableAlterations.copy(
            structure(fks: [selfFK]), to: target, options: CopyOptions(mode: .structureOnly, addConstraints: true), dialect: my)
        #expect(plan.statements.last == "ALTER TABLE `archive`.`orders_copy` ADD FOREIGN KEY (`parent_id`) REFERENCES `archive`.`orders_copy` (`id`) ON DELETE SET NULL")
    }

    @Test func quotesAwkwardNames() throws {
        let weird = TableRef(schema: "my`db", name: "t`1")
        let plan = try TableAlterations.copy(structure(), to: weird, options: CopyOptions(mode: .structureOnly), dialect: my)
        #expect(plan.statements == ["CREATE TABLE `my``db`.`t``1` LIKE `shop`.`orders`"])
    }

    @Test func rejectsSameTargetAndViews() {
        #expect(throws: TableAlterationError.self) { try TableAlterations.copy(structure(), to: table, options: CopyOptions(), dialect: my) }
        #expect(throws: TableAlterationError.self) { try TableAlterations.copy(structure(kind: .view), to: target, options: CopyOptions(), dialect: pg) }
    }
}

@Suite("Table alterations: maintenance and emptying")
struct MaintenanceCommandTests {
    @Test func mysqlCommands() throws {
        #expect(try TableAlterations.maintenance(.analyze, on: table, dialect: my) == "ANALYZE TABLE `shop`.`orders`")
        #expect(try TableAlterations.maintenance(.check, on: table, dialect: my) == "CHECK TABLE `shop`.`orders`")
        #expect(try TableAlterations.maintenance(.checksum, on: table, dialect: my) == "CHECKSUM TABLE `shop`.`orders`")
        #expect(try TableAlterations.maintenance(.optimize, on: table, dialect: my) == "OPTIMIZE TABLE `shop`.`orders`")
        #expect(try TableAlterations.maintenance(.flush, on: table, dialect: my) == "FLUSH TABLE `shop`.`orders`")
        #expect(try TableAlterations.maintenance(.repair, on: table, dialect: my) == "REPAIR TABLE `shop`.`orders`")
        #expect(throws: TableAlterationError.self) { try TableAlterations.maintenance(.vacuum, on: table, dialect: my) }
    }

    @Test func postgresCommands() throws {
        #expect(try TableAlterations.maintenance(.analyze, on: table, dialect: pg) == "ANALYZE \"shop\".\"orders\"")
        #expect(try TableAlterations.maintenance(.vacuum, on: table, dialect: pg) == "VACUUM \"shop\".\"orders\"")
        #expect(try TableAlterations.maintenance(.vacuumFull, on: table, dialect: pg) == "VACUUM (FULL) \"shop\".\"orders\"")
        #expect(try TableAlterations.maintenance(.reindex, on: table, dialect: pg) == "REINDEX TABLE \"shop\".\"orders\"")
        #expect(throws: TableAlterationError.self) { try TableAlterations.maintenance(.checksum, on: table, dialect: pg) }
    }

    @Test func repairOnlyOffersForNonTransactionalEngines() {
        #expect(!TableAlterations.availableMaintenance(dialect: my, storageEngine: "InnoDB").contains(.repair))
        #expect(TableAlterations.availableMaintenance(dialect: my, storageEngine: "MyISAM").contains(.repair))
        #expect(TableAlterations.availableMaintenance(dialect: pg, storageEngine: nil) == [.analyze, .vacuum, .vacuumFull, .reindex])
    }

    @Test func emptyingStatements() {
        #expect(TableAlterations.deleteAllRows(TableRef(schema: "a`b", name: "c"), dialect: my) == "DELETE FROM `a``b`.`c`")
        #expect(TableAlterations.deleteAllRows(table, dialect: pg) == "DELETE FROM \"shop\".\"orders\"")
    }

    @Test func guardTreatsMaintenanceAsWritesButChecksumAsRead() {
        let classifier = StatementClassifier(dialect: my)
        for sql in ["ANALYZE TABLE `a`.`b`", "CHECK TABLE `a`.`b`", "OPTIMIZE TABLE `a`.`b`", "FLUSH TABLE `a`.`b`", "REPAIR TABLE `a`.`b`"] {
            #expect(classifier.classify(text: sql).kind.isWriteLike, "\(sql)")
        }
        let pgClassifier = StatementClassifier(dialect: pg)
        for sql in ["VACUUM \"a\".\"b\"", "VACUUM (FULL) \"a\".\"b\"", "REINDEX TABLE \"a\".\"b\"", "ANALYZE \"a\".\"b\"", "COMMENT ON TABLE \"a\".\"b\" IS NULL"] {
            #expect(pgClassifier.classify(text: sql).kind.isWriteLike, "\(sql)")
        }
        #expect(classifier.classify(text: "DELETE FROM `a`.`b`").isUnfilteredMutation)
    }
}

@Suite("Trigger DDL")
struct TriggerDDLTests {
    private let mysqlSpec = TriggerSpec(
        name: "orders_bi", timing: .before, events: [.insert], body: .statements("BEGIN\n SET NEW.created = NOW();\nEND;"))

    @Test func mysqlCreate() throws {
        let sql = try TriggerDDL.create(mysqlSpec, on: table, dialect: my)
        #expect(sql == ["CREATE TRIGGER `shop`.`orders_bi` BEFORE INSERT ON `shop`.`orders` FOR EACH ROW BEGIN\n SET NEW.created = NOW();\nEND"])
    }

    @Test func mysqlNameWithBacktickAndSingleStatementBody() throws {
        let spec = TriggerSpec(name: "a`b", timing: .after, events: [.delete], body: .statements("  DELETE FROM log WHERE id = OLD.id;  "))
        let sql = try TriggerDDL.create(spec, on: TableRef(schema: "d`b", name: "t"), dialect: my)
        #expect(sql == ["CREATE TRIGGER `d``b`.`a``b` AFTER DELETE ON `d``b`.`t` FOR EACH ROW DELETE FROM log WHERE id = OLD.id"])
    }

    @Test func mysqlValidation() {
        let two = TriggerSpec(name: "x", timing: .before, events: [.insert, .update], body: .statements("SET @a=1"))
        #expect(throws: TriggerError.self) { try TriggerDDL.create(two, on: table, dialect: my) }
        let instead = TriggerSpec(name: "x", timing: .insteadOf, events: [.insert], body: .statements("SET @a=1"))
        #expect(throws: TriggerError.self) { try TriggerDDL.create(instead, on: table, dialect: my) }
        let empty = TriggerSpec(name: "x", timing: .before, events: [.insert], body: .statements(" ;; "))
        #expect(throws: TriggerError.self) { try TriggerDDL.create(empty, on: table, dialect: my) }
        let noName = TriggerSpec(name: " ", timing: .before, events: [.insert], body: .statements("SET @a=1"))
        #expect(throws: TriggerError.self) { try TriggerDDL.create(noName, on: table, dialect: my) }
        let truncate = TriggerSpec(name: "x", timing: .before, events: [.truncate], body: .statements("SET @a=1"))
        #expect(throws: TriggerError.self) { try TriggerDDL.create(truncate, on: table, dialect: my) }
    }

    @Test func postgresWithExistingFunction() throws {
        let spec = TriggerSpec(
            name: "audit", timing: .after, events: [.insert, .update], forEachRow: true, whenCondition: "NEW.total > 0",
            body: .existingFunction(TableRef(schema: "shop", name: "audit_fn")))
        let sql = try TriggerDDL.create(spec, on: table, dialect: pg)
        #expect(sql == ["CREATE TRIGGER \"audit\" AFTER INSERT OR UPDATE ON \"shop\".\"orders\" FOR EACH ROW WHEN (NEW.total > 0) EXECUTE FUNCTION \"shop\".\"audit_fn\"()"])
    }

    @Test func postgresNewFunctionChoosesSafeDollarTag() throws {
        let body = "BEGIN\n  PERFORM $qw$x$qw$;\n  RETURN NEW;\nEND;"
        let spec = TriggerSpec(name: "t\"q", timing: .before, events: [.update], body: .newFunction(TableRef(schema: "shop", name: "fn"), source: body))
        let sql = try TriggerDDL.create(spec, on: table, dialect: pg)
        #expect(sql.count == 2)
        #expect(sql[0].hasPrefix("CREATE OR REPLACE FUNCTION \"shop\".\"fn\"() RETURNS trigger LANGUAGE plpgsql AS $qw1$\n"))
        #expect(sql[0].hasSuffix("\n$qw1$"))
        #expect(sql[1] == "CREATE TRIGGER \"t\"\"q\" BEFORE UPDATE ON \"shop\".\"orders\" FOR EACH ROW EXECUTE FUNCTION \"shop\".\"fn\"()")
    }

    @Test func postgresTruncateAndInsteadOfRules() throws {
        let fn = TriggerSpec.Body.existingFunction(TableRef(schema: "shop", name: "f"))
        let stmt = TriggerSpec(name: "t", timing: .after, events: [.truncate], forEachRow: false, body: fn)
        #expect(try TriggerDDL.create(stmt, on: table, dialect: pg)[0].contains("FOR EACH STATEMENT"))
        let row = TriggerSpec(name: "t", timing: .after, events: [.truncate], forEachRow: true, body: fn)
        #expect(throws: TriggerError.self) { try TriggerDDL.create(row, on: table, dialect: pg) }
        let instead = TriggerSpec(name: "t", timing: .insteadOf, events: [.insert], forEachRow: false, body: fn)
        #expect(throws: TriggerError.self) { try TriggerDDL.create(instead, on: table, dialect: pg) }
        let mysqlBodyOnPG = TriggerSpec(name: "t", timing: .after, events: [.insert], body: .statements("x"))
        #expect(throws: TriggerError.self) { try TriggerDDL.create(mysqlBodyOnPG, on: table, dialect: pg) }
    }

    @Test func dropSyntaxDiffersByFamily() {
        let info = TriggerInfo(name: "tr`g", table: table, timing: .before, events: [.insert], statement: "")
        #expect(TriggerDDL.drop(info, dialect: my) == "DROP TRIGGER `shop`.`tr``g`")
        #expect(TriggerDDL.drop(info, dialect: pg) == "DROP TRIGGER \"tr`g\" ON \"shop\".\"orders\"")
        #expect(TriggerDDL.showCreate(info, dialect: my) == "SHOW CREATE TRIGGER `shop`.`tr``g`")
        #expect(TriggerDDL.showCreate(info, dialect: pg) == nil)
    }

    @Test func replaceStrategyFollowsServerVersion() {
        func server(_ engine: DatabaseEngine, _ major: Int, _ minor: Int = 0) -> ServerInfo {
            ServerInfo(engine: engine, versionString: "\(major).\(minor)", major: major, minor: minor, patch: 0, tlsActive: false)
        }
        #expect(TriggerDDL.replaceStrategy(for: server(.mysql, 8, 4)) == .dropAndCreate)
        #expect(TriggerDDL.replaceStrategy(for: server(.mariadb, 11, 4)) == .createOrReplace)
        #expect(TriggerDDL.replaceStrategy(for: server(.mariadb, 10, 0)) == .dropAndCreate)
        #expect(TriggerDDL.replaceStrategy(for: server(.postgresql, 16)) == .createOrReplace)
        #expect(TriggerDDL.replaceStrategy(for: server(.postgresql, 13)) == .dropAndCreate)
    }

    @Test func editReplacesInPlaceOrDropsFirst() throws {
        let original = TriggerInfo(name: "orders_bi", table: table, timing: .before, events: [.insert], statement: "x")
        let atomic = try TriggerDDL.replace(original: original, with: mysqlSpec, strategy: .createOrReplace, dialect: my)
        #expect(atomic.count == 1)
        #expect(atomic[0].hasPrefix("CREATE OR REPLACE TRIGGER `shop`.`orders_bi`"))

        let sequence = try TriggerDDL.replace(original: original, with: mysqlSpec, strategy: .dropAndCreate, dialect: my)
        #expect(sequence.count == 2)
        #expect(sequence[0] == "DROP TRIGGER `shop`.`orders_bi`")
        #expect(sequence[1].hasPrefix("CREATE TRIGGER "))

        var renamed = mysqlSpec
        renamed.name = "orders_bi2"
        let viaRename = try TriggerDDL.replace(original: original, with: renamed, strategy: .createOrReplace, dialect: my)
        #expect(viaRename.count == 2)
        #expect(viaRename[0] == "DROP TRIGGER `shop`.`orders_bi`")
    }

    @Test func postgresEditCreatesFunctionBeforeDroppingTrigger() throws {
        let original = TriggerInfo(name: "audit", table: table, timing: .after, events: [.insert], statement: "")
        let spec = TriggerSpec(name: "audit", timing: .after, events: [.insert], body: .newFunction(TableRef(schema: "shop", name: "fn"), source: "BEGIN RETURN NULL; END;"))
        let seq = try TriggerDDL.replace(original: original, with: spec, strategy: .dropAndCreate, dialect: pg)
        #expect(seq.count == 3)
        #expect(seq[0].hasPrefix("CREATE OR REPLACE FUNCTION"))
        #expect(seq[1] == "DROP TRIGGER \"audit\" ON \"shop\".\"orders\"")
        #expect(seq[2].hasPrefix("CREATE TRIGGER"))
    }

    @Test func postgresTriggerTypeDecoding() {
        // BEFORE INSERT OR UPDATE FOR EACH ROW = row(1) + before(2) + insert(4) + update(16)
        let a = PostgresSchemaInspector.decodeTriggerType(1 + 2 + 4 + 16)
        #expect(a.timing == .before && a.events == [.insert, .update] && a.forEachRow)
        let b = PostgresSchemaInspector.decodeTriggerType(8)  // AFTER DELETE, statement level
        #expect(b.timing == .after && b.events == [.delete] && !b.forEachRow)
        let c = PostgresSchemaInspector.decodeTriggerType(1 + 64 + 4)  // INSTEAD OF INSERT
        #expect(c.timing == .insteadOf)
        #expect(PostgresSchemaInspector.decodeTriggerType(32).events == [.truncate])
    }
}
