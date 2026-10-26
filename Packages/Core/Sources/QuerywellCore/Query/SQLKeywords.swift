import Foundation

/// Keyword and function vocabularies per dialect family (MySQL 8 / MariaDB, PostgreSQL 16).
/// Shared by the highlighter, the autocomplete and the formatter. All entries are uppercase.
public enum SQLKeywords {
    public static func keywords(for family: SQLDialect.Family) -> Set<String> {
        switch family {
        case .mysql: mysqlKeywords
        case .postgres: postgresKeywords
        }
    }

    public static func functions(for family: SQLDialect.Family) -> Set<String> {
        switch family {
        case .mysql: mysqlFunctions
        case .postgres: postgresFunctions
        }
    }

    /// Keywords sorted for completion lists.
    public static func sortedKeywords(for family: SQLDialect.Family) -> [String] {
        switch family {
        case .mysql: mysqlSorted
        case .postgres: postgresSorted
        }
    }

    public static func sortedFunctions(for family: SQLDialect.Family) -> [String] {
        switch family {
        case .mysql: mysqlFunctionsSorted
        case .postgres: postgresFunctionsSorted
        }
    }

    /// Words that begin a statement (offered at the start of an empty statement).
    public static let statementStarters: [String] = [
        "SELECT", "INSERT", "UPDATE", "DELETE", "WITH", "CREATE", "ALTER", "DROP", "TRUNCATE", "SHOW",
        "DESCRIBE", "EXPLAIN", "USE", "SET", "BEGIN", "COMMIT", "ROLLBACK", "GRANT", "REVOKE", "CALL",
    ]

    // MARK: Shared core

    private static let common: Set<String> = [
        "ADD", "ALL", "ALTER", "AND", "ANY", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASE", "CAST", "CHECK",
        "COLUMN", "COMMIT", "CONSTRAINT", "CREATE", "CROSS", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
        "DATABASE", "DEFAULT", "DELETE", "DESC", "DESCRIBE", "DISTINCT", "DROP", "ELSE", "END", "EXCEPT",
        "EXISTS", "EXPLAIN", "FALSE", "FETCH", "FOREIGN", "FROM", "FULL", "GRANT", "GROUP", "HAVING", "IF",
        "IN", "INDEX", "INNER", "INSERT", "INTERSECT", "INTO", "IS", "JOIN", "KEY", "LEFT", "LIKE", "LIMIT",
        "NATURAL", "NOT", "NULL", "OFFSET", "ON", "OR", "ORDER", "OUTER", "OVER", "PARTITION", "PRIMARY",
        "PROCEDURE", "REFERENCES", "RENAME", "REPLACE", "REVOKE", "RIGHT", "ROLLBACK", "ROW", "ROWS", "SELECT",
        "SET", "SHOW", "TABLE", "THEN", "TO", "TRIGGER", "TRUE", "TRUNCATE", "UNION", "UNIQUE", "UPDATE",
        "USE", "USING", "VALUES", "VIEW", "WHEN", "WHERE", "WINDOW", "WITH", "RECURSIVE", "RETURNING",
        "CALL", "DO", "LATERAL", "FOR", "NO", "ACTION", "CASCADE", "RESTRICT", "SAVEPOINT", "RELEASE",
        "TRANSACTION", "START", "ESCAPE", "UNBOUNDED", "PRECEDING", "FOLLOWING", "CURRENT", "RANGE",
    ]

    private static let mysqlOnly: Set<String> = [
        "AUTO_INCREMENT", "BINARY", "CHARACTER", "CHARSET", "COLLATE", "COMMENT", "CONVERT", "DELAYED",
        "DIV", "DUPLICATE", "ENGINE", "ENUM", "EXPLAIN", "FORCE", "FULLTEXT", "GENERATED", "HIGH_PRIORITY",
        "IGNORE", "INTERVAL", "KEYS", "LOCK", "LOW_PRIORITY", "MOD", "NAMES", "OPTIMIZE", "ANALYZE", "REGEXP",
        "RLIKE", "SCHEMA", "SIGNED", "SPATIAL", "SQL_CALC_FOUND_ROWS", "SQL_NO_CACHE", "STRAIGHT_JOIN",
        "TABLES", "TEMPORARY", "UNLOCK", "UNSIGNED", "VIRTUAL", "XOR", "ZEROFILL", "DATABASES", "COLUMNS",
        "STATUS", "VARIABLES", "PROCESSLIST", "ENGINES", "INDEXES", "PARTITIONS", "OUTFILE", "INFILE",
        "LOAD", "DATA", "LOCAL", "ROLLUP", "SEPARATOR", "SHARE", "MODE", "NOWAIT", "SKIP", "LOCKED",
        "IDENTIFIED", "PASSWORD", "USER", "ROLE", "TRIGGERS", "EVENT", "EVENTS", "FUNCTION", "ITERATE",
        "LEAVE", "LOOP", "REPEAT", "UNTIL", "WHILE", "DECLARE", "HANDLER", "CURSOR", "SIGNAL", "RESIGNAL",
    ]

    private static let postgresOnly: Set<String> = [
        "ANALYZE", "ARRAY", "AUTHORIZATION", "BIGSERIAL", "CONCURRENTLY", "CONFLICT", "COPY", "DEFERRABLE",
        "EXTENSION", "FILTER", "FUNCTION", "GENERATED", "IDENTITY", "ILIKE", "INHERITS", "INITIALLY",
        "ISNULL", "NOTNULL", "MATERIALIZED", "NOTHING", "ONLY", "OWNER", "PLPGSQL", "RETURNS", "SCHEMA",
        "SEQUENCE", "SERIAL", "SIMILAR", "TABLESPACE", "TEMP", "TEMPORARY", "TYPE", "UNLOGGED", "VACUUM",
        "VERBOSE", "WITHIN", "ORDINALITY", "ROLE", "LANGUAGE", "DOMAIN", "ENUM", "COLLATE", "REINDEX",
        "REFRESH", "LISTEN", "NOTIFY", "RULE", "POLICY", "TABLESAMPLE", "SKIP", "LOCKED", "NOWAIT", "SHARE",
        "CUBE", "ROLLUP", "GROUPING", "SETS", "DISTINCT", "SYMMETRIC", "ASYMMETRIC", "BINARY", "FREEZE",
    ]

    private static let mysqlKeywords: Set<String> = common.union(mysqlOnly)
    private static let postgresKeywords: Set<String> = common.union(postgresOnly)
    private static let mysqlSorted: [String] = mysqlKeywords.sorted()
    private static let postgresSorted: [String] = postgresKeywords.sorted()

    // MARK: Functions

    private static let commonFunctions: Set<String> = [
        "ABS", "AVG", "CEIL", "CEILING", "COALESCE", "CONCAT", "COUNT", "CURRENT_DATE", "CURRENT_TIMESTAMP",
        "EXP", "FLOOR", "GREATEST", "LEAST", "LENGTH", "LOWER", "LTRIM", "MAX", "MIN", "MOD", "NULLIF", "NOW",
        "POWER", "RANK", "DENSE_RANK", "ROW_NUMBER", "ROUND", "RTRIM", "SIGN", "SQRT", "SUBSTRING", "SUM",
        "TRIM", "UPPER", "LEFT", "RIGHT", "REPLACE", "REPEAT", "REVERSE", "POSITION", "LAG", "LEAD",
        "FIRST_VALUE", "LAST_VALUE", "NTILE", "CAST", "EXTRACT", "IF", "LN", "LOG", "LOG10", "SIN", "COS",
        "TAN", "PI", "RANDOM", "LPAD", "RPAD", "OVERLAY", "CURRENT_TIME", "STDDEV", "VARIANCE",
        "PERCENT_RANK", "CUME_DIST", "NTH_VALUE", "TRUNC",
    ]

    private static let mysqlFunctionList: Set<String> = commonFunctions.union([
        "ADDDATE", "AES_ENCRYPT", "AES_DECRYPT", "ANY_VALUE", "ASCII", "BIN", "BIT_AND", "BIT_COUNT", "BIT_OR",
        "BIT_XOR", "CHAR_LENGTH", "CHARACTER_LENGTH", "CHAR", "CONCAT_WS", "CONV", "CONVERT_TZ", "CURDATE",
        "CURTIME", "DATABASE", "DATE", "DATE_ADD", "DATE_FORMAT", "DATE_SUB", "DATEDIFF", "DAY", "DAYNAME",
        "DAYOFMONTH", "DAYOFWEEK", "DAYOFYEAR", "ELT", "FIELD", "FIND_IN_SET", "FORMAT", "FOUND_ROWS",
        "FROM_BASE64", "FROM_DAYS", "FROM_UNIXTIME", "GROUP_CONCAT", "HEX", "HOUR", "IFNULL", "INET_ATON",
        "INET_NTOA", "INSERT", "INSTR", "ISNULL", "JSON_ARRAY", "JSON_ARRAYAGG", "JSON_CONTAINS", "JSON_EXTRACT",
        "JSON_KEYS", "JSON_LENGTH", "JSON_MERGE_PATCH", "JSON_OBJECT", "JSON_OBJECTAGG", "JSON_REMOVE",
        "JSON_SEARCH", "JSON_SET", "JSON_TABLE", "JSON_TYPE", "JSON_UNQUOTE", "JSON_VALID", "LAST_DAY",
        "LAST_INSERT_ID", "LCASE", "LOCATE", "MAKEDATE", "MD5", "MICROSECOND", "MID", "MINUTE", "MONTH",
        "MONTHNAME", "OCT", "ORD", "QUARTER", "RAND", "REGEXP_LIKE", "REGEXP_REPLACE", "REGEXP_SUBSTR",
        "ROW_COUNT", "SECOND", "SEC_TO_TIME", "SHA1", "SHA2", "SLEEP", "SPACE", "STR_TO_DATE", "STRCMP",
        "SUBDATE", "SUBSTR", "SUBSTRING_INDEX", "SYSDATE", "TIME", "TIME_FORMAT", "TIME_TO_SEC", "TIMEDIFF",
        "TIMESTAMP", "TIMESTAMPADD", "TIMESTAMPDIFF", "TO_BASE64", "TO_DAYS", "UCASE", "UNHEX", "UNIX_TIMESTAMP",
        "USER", "UTC_TIMESTAMP", "UUID", "UUID_SHORT", "VERSION", "WEEK", "WEEKDAY", "WEEKOFYEAR", "YEAR",
        "YEARWEEK", "BIT_LENGTH", "OCTET_LENGTH", "LOAD_FILE", "COMPRESS", "UNCOMPRESS", "CURRENT_USER",
        "CONNECTION_ID", "MATCH", "ST_DISTANCE", "ST_ASTEXT", "ST_GEOMFROMTEXT", "BENCHMARK",
    ])

    private static let postgresFunctionList: Set<String> = commonFunctions.union([
        "ARRAY_AGG", "ARRAY_APPEND", "ARRAY_LENGTH", "ARRAY_TO_STRING", "AGE", "BOOL_AND", "BOOL_OR",
        "BTRIM", "CHAR_LENGTH", "CLOCK_TIMESTAMP", "CONCAT_WS", "CURRENT_SCHEMA", "CURRENT_USER", "DATE_PART",
        "DATE_TRUNC", "DIV", "ENCODE", "DECODE", "FORMAT", "GENERATE_SERIES", "GEN_RANDOM_UUID", "INITCAP",
        "JSON_AGG", "JSON_BUILD_ARRAY", "JSON_BUILD_OBJECT", "JSON_EACH", "JSON_EXTRACT_PATH",
        "JSONB_AGG", "JSONB_BUILD_ARRAY", "JSONB_BUILD_OBJECT", "JSONB_EACH", "JSONB_SET", "JSONB_PATH_QUERY",
        "JSONB_ARRAY_ELEMENTS", "JSONB_OBJECT_KEYS", "MAKE_DATE", "MD5", "NEXTVAL", "CURRVAL", "SETVAL",
        "PG_SIZE_PRETTY", "PG_TOTAL_RELATION_SIZE", "PG_RELATION_SIZE", "PG_TABLE_SIZE", "PG_BACKEND_PID",
        "QUOTE_IDENT", "QUOTE_LITERAL", "REGEXP_MATCH", "REGEXP_REPLACE", "REGEXP_SPLIT_TO_ARRAY",
        "REGEXP_SPLIT_TO_TABLE", "SPLIT_PART", "STARTS_WITH", "STATEMENT_TIMESTAMP", "STRING_AGG",
        "STRING_TO_ARRAY", "STRPOS", "TO_CHAR", "TO_DATE", "TO_JSON", "TO_JSONB", "TO_NUMBER", "TO_TIMESTAMP",
        "TO_TSVECTOR", "TO_TSQUERY", "PLAINTO_TSQUERY", "TS_RANK", "TRANSACTION_TIMESTAMP", "TRANSLATE",
        "UNNEST", "VERSION", "WIDTH_BUCKET", "PERCENTILE_CONT", "PERCENTILE_DISC", "MODE", "EVERY",
        "ROW_TO_JSON", "ISFINITE", "NUM_NONNULLS", "NUM_NULLS", "SETSEED", "MAKE_TIMESTAMP", "LOWER_INC",
    ])

    private static let mysqlFunctions: Set<String> = mysqlFunctionList
    private static let postgresFunctions: Set<String> = postgresFunctionList
    private static let mysqlFunctionsSorted: [String] = mysqlFunctions.sorted()
    private static let postgresFunctionsSorted: [String] = postgresFunctions.sorted()
}
