import Foundation

/// mysqldump-shaped fixtures. DDL spots that the rewriter may change are written as placeholders
/// (`%C4%` etc.) so that the *expected* output is simply the same template rendered with the target
/// names — everything else (notably INSERT data) must be byte-identical.
enum DumpFixtures {
    struct Names {
        var c4 = "utf8mb4_0900_ai_ci"
        var cs3 = "utf8mb3"
        var c3 = "utf8mb3_general_ci"
    }

    static func render(_ template: String, _ n: Names) -> String {
        template
            .replacingOccurrences(of: "%C4%", with: n.c4)
            .replacingOccurrences(of: "%CS3%", with: n.cs3)
            .replacingOccurrences(of: "%C3%", with: n.c3)
    }

    /// Modelled on mysqldump 8.4 (`--routines --triggers --events` defaults). `%C4%` is the server
    /// default collation, `%CS3%`/`%C3%` the utf8mb3 charset / collation.
    static let mysql84Template = #"""
    -- MySQL dump 10.13  Distrib 8.4.0, for Linux (x86_64)
    --
    -- Host: localhost    Database: shop
    -- ------------------------------------------------------
    -- Server version	8.4.0

    /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
    /*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
    /*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
    /*!50503 SET NAMES utf8mb4 */;
    /*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
    /*!40103 SET TIME_ZONE='+00:00' */;
    /*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
    /*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
    /*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
    /*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

    --
    -- Current Database: `shop`
    --

    CREATE DATABASE /*!32312 IF NOT EXISTS*/ `shop` /*!40100 DEFAULT CHARACTER SET utf8mb4 COLLATE %C4% */ /*!80016 DEFAULT ENCRYPTION='N' */;

    USE `shop`;

    --
    -- Table structure for table `wp_options`
    --

    DROP TABLE IF EXISTS `wp_options`;
    /*!40101 SET @saved_cs_client     = @@character_set_client */;
    /*!50503 SET character_set_client = utf8mb4 */;
    CREATE TABLE `wp_options` (
      `option_id` bigint unsigned NOT NULL AUTO_INCREMENT,
      `option_name` varchar(191) COLLATE %C4% NOT NULL DEFAULT '',
      `option_value` longtext COLLATE %C4% NOT NULL,
      `autoload` varchar(20) COLLATE %C4% NOT NULL DEFAULT 'yes',
      PRIMARY KEY (`option_id`),
      UNIQUE KEY `option_name` (`option_name`),
      KEY `autoload` (`autoload`)
    ) ENGINE=InnoDB AUTO_INCREMENT=1234 DEFAULT CHARSET=utf8mb4 COLLATE=%C4%;
    /*!40101 SET character_set_client = @saved_cs_client */;

    --
    -- Dumping data for table `wp_options`
    --

    LOCK TABLES `wp_options` WRITE;
    /*!40000 ALTER TABLE `wp_options` DISABLE KEYS */;
    INSERT INTO `wp_options` VALUES (1,'siteurl','http://old.test','yes'),(2,'note','COLLATE utf8mb4_0900_ai_ci and DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci','yes'),(3,'esc','it''s a \'quote\' ; CREATE TABLE x (a int) COLLATE utf8mb4_0900_ai_ci; -- c /* d */ # e','no'),(4,'multi','line1\nline2 \\','no'),(5,'cs','SET NAMES utf8mb4 COLLATE utf8mb4_0900_ai_ci;','no'),(6,'uni','Café 日本語 😀 _utf8mb3\'x\' utf8mb3_general_ci','yes');
    /*!40000 ALTER TABLE `wp_options` ENABLE KEYS */;
    UNLOCK TABLES;

    --
    -- Table structure for table `legacy`
    --

    DROP TABLE IF EXISTS `legacy`;
    /*!40101 SET @saved_cs_client     = @@character_set_client */;
    /*!50503 SET character_set_client = utf8mb4 */;
    CREATE TABLE `legacy` (
      `a` varchar(10) CHARACTER SET latin1 COLLATE latin1_swedish_ci DEFAULT NULL,
      `b` varchar(10) CHARACTER SET %CS3% COLLATE %C3% DEFAULT 'utf8mb4_0900_ai_ci' COMMENT 'COLLATE utf8mb4_0900_ai_ci',
      `c` varbinary(10) DEFAULT NULL,
      `d` varchar(10) CHARACTER SET binary DEFAULT NULL,
      `e` char(3) COLLATE utf8mb4_bin DEFAULT NULL,
      `utf8mb4_0900_ai_ci` int DEFAULT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=%CS3% COLLATE=%C3% COMMENT='CHARSET=utf8mb4 note';
    /*!40101 SET character_set_client = @saved_cs_client */;

    LOCK TABLES `legacy` WRITE;
    /*!40000 ALTER TABLE `legacy` DISABLE KEYS */;
    INSERT INTO `legacy` VALUES ('a','b',NULL,NULL,'e',1);
    INSERT INTO `legacy` VALUES (_utf8mb3'x',_binary 'y',0x00,NULL,'utf8mb4_0900_ai_ci',2);
    /*!40000 ALTER TABLE `legacy` ENABLE KEYS */;
    UNLOCK TABLES;

    --
    -- Temporary view structure for view `v_opts`
    --

    DROP TABLE IF EXISTS `v_opts`;
    /*!50001 DROP VIEW IF EXISTS `v_opts`*/;
    SET @saved_cs_client     = @@character_set_client;
    /*!50503 SET character_set_client = utf8mb4 */;
    /*!50001 CREATE VIEW `v_opts` AS SELECT 1 AS `option_id` */;
    SET character_set_client = @saved_cs_client;

    --
    -- Final view structure for view `v_opts`
    --

    /*!50001 DROP VIEW IF EXISTS `v_opts`*/;
    /*!50001 SET @saved_cs_client          = @@character_set_client */;
    /*!50001 SET @saved_cs_results         = @@character_set_results */;
    /*!50001 SET @saved_col_connection     = @@collation_connection */;
    /*!50001 SET character_set_client      = utf8mb4 */;
    /*!50001 SET character_set_results     = utf8mb4 */;
    /*!50001 SET collation_connection      = %C4% */;
    /*!50001 CREATE ALGORITHM=UNDEFINED */
    /*!50013 DEFINER=`root`@`localhost` SQL SECURITY DEFINER */
    /*!50001 VIEW `v_opts` AS select `wp_options`.`option_id` AS `option_id` from `wp_options` where (`wp_options`.`option_name` = 'COLLATE utf8mb4_0900_ai_ci') */;
    /*!50001 SET character_set_client      = @saved_cs_client */;
    /*!50001 SET character_set_results     = @saved_cs_results */;
    /*!50001 SET collation_connection      = @saved_col_connection */;

    --
    -- Dumping routines for database 'shop'
    --
    /*!50003 DROP PROCEDURE IF EXISTS `p_touch` */;
    /*!50003 SET @saved_cs_client      = @@character_set_client */ ;
    /*!50003 SET @saved_cs_results     = @@character_set_results */ ;
    /*!50003 SET @saved_col_connection = @@collation_connection */ ;
    /*!50003 SET character_set_client  = utf8mb4 */ ;
    /*!50003 SET character_set_results = utf8mb4 */ ;
    /*!50003 SET collation_connection  = %C4% */ ;
    /*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
    /*!50003 SET sql_mode              = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION' */ ;
    DELIMITER ;;
    CREATE DEFINER=`root`@`localhost` PROCEDURE `p_touch`(IN name VARCHAR(50) CHARSET %CS3%)
    BEGIN
      UPDATE wp_options SET option_value = 'COLLATE utf8mb4_0900_ai_ci; still data' WHERE option_name = name COLLATE %C4%;
      INSERT INTO legacy VALUES ('x','y',NULL,NULL,'z',3);
    END ;;
    DELIMITER ;
    /*!50003 SET sql_mode              = @saved_sql_mode */ ;
    /*!50003 SET character_set_client  = @saved_cs_client */ ;
    /*!50003 SET character_set_results = @saved_cs_results */ ;
    /*!50003 SET collation_connection  = @saved_col_connection */ ;

    --
    -- Dumping events for database 'shop'
    --

    --
    -- Dumping triggers for database 'shop'
    --

    /*!50003 SET @saved_cs_client      = @@character_set_client */ ;
    /*!50003 SET @saved_cs_results     = @@character_set_results */ ;
    /*!50003 SET @saved_col_connection = @@collation_connection */ ;
    /*!50003 SET character_set_client  = utf8mb4 */ ;
    /*!50003 SET character_set_results = utf8mb4 */ ;
    /*!50003 SET collation_connection  = %C4% */ ;
    /*!50003 SET @saved_sql_mode       = @@sql_mode */ ;
    /*!50003 SET sql_mode              = 'ONLY_FULL_GROUP_BY' */ ;
    DELIMITER ;;
    /*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER `trg_opts` BEFORE INSERT ON `wp_options` FOR EACH ROW BEGIN
      SET NEW.option_name = LOWER(NEW.option_name) COLLATE %C4%;
      IF NEW.option_value = 'COLLATE utf8mb4_0900_ai_ci' THEN SET NEW.autoload = 'no'; END IF;
    END */;;
    DELIMITER ;
    /*!50003 SET sql_mode              = @saved_sql_mode */ ;
    /*!50003 SET character_set_client  = @saved_cs_client */ ;
    /*!50003 SET character_set_results = @saved_cs_results */ ;
    /*!50003 SET collation_connection  = @saved_col_connection */ ;
    /*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

    /*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
    /*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
    /*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
    /*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
    /*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
    /*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
    /*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

    -- Dump completed on 2026-10-26 12:00:00

    """#

    /// Modelled on mariadb-dump 11.4. `%C4%` is `utf8mb4_uca1400_ai_ci` (the 11.4 default).
    static let mariadb11Template = #"""
    /*M!999999\- enable the sandbox mode */
    -- MariaDB dump 10.19-11.4.2-MariaDB, for debian-linux-gnu (x86_64)
    --
    -- Host: localhost    Database: blog
    -- ------------------------------------------------------
    -- Server version	11.4.2-MariaDB-ubu2404

    /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
    /*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
    /*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
    /*!40101 SET NAMES utf8mb4 */;
    /*M!100616 SET @OLD_NOTE_VERBOSITY=@@NOTE_VERBOSITY, NOTE_VERBOSITY=0 */;
    /*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
    /*!40103 SET TIME_ZONE='+00:00' */;
    /*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;

    --
    -- Current Database: `blog`
    --

    CREATE DATABASE /*!32312 IF NOT EXISTS*/ `blog` /*!40100 DEFAULT CHARACTER SET utf8mb4 COLLATE %C4% */;

    USE `blog`;

    --
    -- Table structure for table `wp_posts`
    --

    DROP TABLE IF EXISTS `wp_posts`;
    /*!40101 SET @saved_cs_client     = @@character_set_client */;
    /*!40101 SET character_set_client = utf8mb4 */;
    CREATE TABLE `wp_posts` (
      `ID` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
      `post_title` text COLLATE %C4% NOT NULL,
      `post_name` varchar(200) CHARACTER SET %CS3% COLLATE %C3% NOT NULL DEFAULT '',
      `post_content` longtext CHARACTER SET utf8mb4 COLLATE %C4% NOT NULL,
      PRIMARY KEY (`ID`),
      KEY `post_name` (`post_name`(191))
    ) ENGINE=InnoDB AUTO_INCREMENT=5 DEFAULT CHARSET=utf8mb4 COLLATE=%C4%;
    /*!40101 SET character_set_client = @saved_cs_client */;

    --
    -- Dumping data for table `wp_posts`
    --

    LOCK TABLES `wp_posts` WRITE;
    /*!40000 ALTER TABLE `wp_posts` DISABLE KEYS */;
    INSERT INTO `wp_posts` VALUES (1,'Hello \"world\"','hello-world','<p>COLLATE=utf8mb4_uca1400_ai_ci</p>'),(2,'Café','cafe','DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;\nCREATE TABLE t (a int);'),(3,'日本語','nihongo',''),(4,'q''uote','quote','--\n/*!40101 SET NAMES latin1 */;');
    /*!40000 ALTER TABLE `wp_posts` ENABLE KEYS */;
    UNLOCK TABLES;

    DELIMITER ;;
    CREATE DEFINER=`root`@`localhost` FUNCTION `f_slug`(s VARCHAR(100) CHARSET utf8mb4) RETURNS varchar(100) CHARSET utf8mb4 COLLATE %C4% DETERMINISTIC
    BEGIN
      RETURN LOWER(s);
    END ;;
    DELIMITER ;
    /*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;
    /*M!100616 SET NOTE_VERBOSITY=@OLD_NOTE_VERBOSITY */;
    /*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
    /*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;

    -- Dump completed on 2026-10-26 12:00:00

    """#

    /// Postgres-style COPY block between DDL (not produced by mysqldump but must be streamed untouched).
    static let copyTemplate = """
    CREATE TABLE a (x text COLLATE %C4%);
    COPY a (x) FROM stdin;
    one\tCOLLATE utf8mb4_0900_ai_ci
    two; CREATE TABLE b (y int) COLLATE utf8mb4_0900_ai_ci;
    three 'unbalanced quote
    \\.
    CREATE TABLE c (z text COLLATE %C4%);

    """
}
