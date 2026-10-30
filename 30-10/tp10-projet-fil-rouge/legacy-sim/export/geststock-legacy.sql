-- MySQL dump 10.19  Distrib 10.3.39-MariaDB, for debian-linux-gnu (aarch64)
--
-- Host: localhost    Database: geststock
-- ------------------------------------------------------
-- Server version	10.3.39-MariaDB-1:10.3.39+maria~ubu2004

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;

--
-- Current Database: `geststock`
--

CREATE DATABASE /*!32312 IF NOT EXISTS*/ `geststock` /*!40100 DEFAULT CHARACTER SET latin1 COLLATE latin1_swedish_ci */;

USE `geststock`;

--
-- Table structure for table `items`
--

DROP TABLE IF EXISTS `items`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `items` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(200) NOT NULL,
  `qty` int(11) NOT NULL DEFAULT 0,
  `photo` varchar(100) DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=157 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

--
-- Dumping data for table `items`
--

LOCK TABLES `items` WRITE;
/*!40000 ALTER TABLE `items` DISABLE KEYS */;
INSERT INTO `items` VALUES (1,'Visserie M4',500,NULL,'2026-10-30 15:16:53'),(2,'Câble HDMI 2m',3,NULL,'2026-10-30 15:16:53'),(3,'Dock USB-C',12,NULL,'2026-10-30 15:16:53'),(4,'Batterie externe',2,NULL,'2026-10-30 15:16:53'),(5,'Article legacy n°1',37,NULL,'2019-01-10 00:00:00'),(6,'Article legacy n°2',74,NULL,'2019-01-19 00:00:00'),(7,'Article legacy n°3',111,NULL,'2019-01-28 00:00:00'),(8,'Article legacy n°4',28,'p_5f000004.31676.jpg','2019-02-06 00:00:00'),(9,'Article legacy n°5',65,NULL,'2019-02-15 00:00:00'),(10,'Article legacy n°6',102,NULL,'2019-02-24 00:00:00'),(11,'Article legacy n°7',19,NULL,'2019-03-05 00:00:00'),(12,'Article legacy n°8',56,'p_5f000008.63352.jpg','2019-03-14 00:00:00'),(13,'Article legacy n°9',93,NULL,'2019-03-23 00:00:00'),(14,'Article legacy n°10',10,NULL,'2019-04-01 00:00:00'),(15,'Article legacy n°11',47,NULL,'2019-04-10 00:00:00'),(16,'Article legacy n°12',84,'p_5f000012.95028.jpg','2019-04-19 00:00:00'),(17,'Article legacy n°13',1,NULL,'2019-04-28 00:00:00'),(18,'Article legacy n°14',38,NULL,'2019-05-07 00:00:00'),(19,'Article legacy n°15',75,NULL,'2019-05-16 00:00:00'),(20,'Article legacy n°16',112,'p_5f000016.126704.jpg','2019-05-25 00:00:00'),(21,'Article legacy n°17',29,NULL,'2019-06-03 00:00:00'),(22,'Article legacy n°18',66,NULL,'2019-06-12 00:00:00'),(23,'Article legacy n°19',103,NULL,'2019-06-21 00:00:00'),(24,'Article legacy n°20',20,'p_5f000020.158380.jpg','2019-06-30 00:00:00'),(25,'Article legacy n°21',57,NULL,'2019-07-09 00:00:00'),(26,'Article legacy n°22',94,NULL,'2019-07-18 00:00:00'),(27,'Article legacy n°23',11,NULL,'2019-07-27 00:00:00'),(28,'Article legacy n°24',48,'p_5f000024.190056.jpg','2019-08-05 00:00:00'),(29,'Article legacy n°25',85,NULL,'2019-08-14 00:00:00'),(30,'Article legacy n°26',2,NULL,'2019-08-23 00:00:00'),(31,'Article legacy n°27',39,NULL,'2019-09-01 00:00:00'),(32,'Article legacy n°28',76,'p_5f000028.221732.jpg','2019-09-10 00:00:00'),(33,'Article legacy n°29',113,NULL,'2019-09-19 00:00:00'),(34,'Article legacy n°30',30,NULL,'2019-09-28 00:00:00'),(35,'Article legacy n°31',67,NULL,'2019-10-07 00:00:00'),(36,'Article legacy n°32',104,'p_5f000032.253408.jpg','2019-10-16 00:00:00'),(37,'Article legacy n°33',21,NULL,'2019-10-25 00:00:00'),(38,'Article legacy n°34',58,NULL,'2019-11-03 00:00:00'),(39,'Article legacy n°35',95,NULL,'2019-11-12 00:00:00'),(40,'Article legacy n°36',12,'p_5f000036.285084.jpg','2019-11-21 00:00:00'),(41,'Article legacy n°37',49,NULL,'2019-11-30 00:00:00'),(42,'Article legacy n°38',86,NULL,'2019-12-09 00:00:00'),(43,'Article legacy n°39',3,NULL,'2019-12-18 00:00:00'),(44,'Article legacy n°40',40,'p_5f000040.316760.jpg','2019-12-27 00:00:00'),(45,'Article legacy n°41',77,NULL,'2020-01-05 00:00:00'),(46,'Article legacy n°42',114,NULL,'2020-01-14 00:00:00'),(47,'Article legacy n°43',31,NULL,'2020-01-23 00:00:00'),(48,'Article legacy n°44',68,'p_5f000044.348436.jpg','2020-02-01 00:00:00'),(49,'Article legacy n°45',105,NULL,'2020-02-10 00:00:00'),(50,'Article legacy n°46',22,NULL,'2020-02-19 00:00:00'),(51,'Article legacy n°47',59,NULL,'2020-02-28 00:00:00'),(52,'Article legacy n°48',96,'p_5f000048.380112.jpg','2020-03-08 00:00:00'),(53,'Article legacy n°49',13,NULL,'2020-03-17 00:00:00'),(54,'Article legacy n°50',50,NULL,'2020-03-26 00:00:00'),(55,'Article legacy n°51',87,NULL,'2020-04-04 00:00:00'),(56,'Article legacy n°52',4,'p_5f000052.411788.jpg','2020-04-13 00:00:00'),(57,'Article legacy n°53',41,NULL,'2020-04-22 00:00:00'),(58,'Article legacy n°54',78,NULL,'2020-05-01 00:00:00'),(59,'Article legacy n°55',115,NULL,'2020-05-10 00:00:00'),(60,'Article legacy n°56',32,'p_5f000056.443464.jpg','2020-05-19 00:00:00'),(61,'Article legacy n°57',69,NULL,'2020-05-28 00:00:00'),(62,'Article legacy n°58',106,NULL,'2020-06-06 00:00:00'),(63,'Article legacy n°59',23,NULL,'2020-06-15 00:00:00'),(64,'Article legacy n°60',60,'p_5f000060.475140.jpg','2020-06-24 00:00:00'),(65,'Article legacy n°61',97,NULL,'2020-07-03 00:00:00'),(66,'Article legacy n°62',14,NULL,'2020-07-12 00:00:00'),(67,'Article legacy n°63',51,NULL,'2020-07-21 00:00:00'),(68,'Article legacy n°64',88,'p_5f000064.506816.jpg','2020-07-30 00:00:00'),(69,'Article legacy n°65',5,NULL,'2020-08-08 00:00:00'),(70,'Article legacy n°66',42,NULL,'2020-08-17 00:00:00'),(71,'Article legacy n°67',79,NULL,'2020-08-26 00:00:00'),(72,'Article legacy n°68',116,'p_5f000068.538492.jpg','2020-09-04 00:00:00'),(73,'Article legacy n°69',33,NULL,'2020-09-13 00:00:00'),(74,'Article legacy n°70',70,NULL,'2020-09-22 00:00:00'),(75,'Article legacy n°71',107,NULL,'2020-10-01 00:00:00'),(76,'Article legacy n°72',24,'p_5f000072.570168.jpg','2020-10-10 00:00:00'),(77,'Article legacy n°73',61,NULL,'2020-10-19 00:00:00'),(78,'Article legacy n°74',98,NULL,'2020-10-28 00:00:00'),(79,'Article legacy n°75',15,NULL,'2020-11-06 00:00:00'),(80,'Article legacy n°76',52,'p_5f000076.601844.jpg','2020-11-15 00:00:00'),(81,'Article legacy n°77',89,NULL,'2020-11-24 00:00:00'),(82,'Article legacy n°78',6,NULL,'2020-12-03 00:00:00'),(83,'Article legacy n°79',43,NULL,'2020-12-12 00:00:00'),(84,'Article legacy n°80',80,'p_5f000080.633520.jpg','2020-12-21 00:00:00'),(85,'Article legacy n°81',117,NULL,'2020-12-30 00:00:00'),(86,'Article legacy n°82',34,NULL,'2021-01-08 00:00:00'),(87,'Article legacy n°83',71,NULL,'2021-01-17 00:00:00'),(88,'Article legacy n°84',108,'p_5f000084.665196.jpg','2021-01-26 00:00:00'),(89,'Article legacy n°85',25,NULL,'2021-02-04 00:00:00'),(90,'Article legacy n°86',62,NULL,'2021-02-13 00:00:00'),(91,'Article legacy n°87',99,NULL,'2021-02-22 00:00:00'),(92,'Article legacy n°88',16,'p_5f000088.696872.jpg','2021-03-03 00:00:00'),(93,'Article legacy n°89',53,NULL,'2021-03-12 00:00:00'),(94,'Article legacy n°90',90,NULL,'2021-03-21 00:00:00'),(95,'Article legacy n°91',7,NULL,'2021-03-30 00:00:00'),(96,'Article legacy n°92',44,'p_5f000092.728548.jpg','2021-04-08 00:00:00'),(97,'Article legacy n°93',81,NULL,'2021-04-17 00:00:00'),(98,'Article legacy n°94',118,NULL,'2021-04-26 00:00:00'),(99,'Article legacy n°95',35,NULL,'2021-05-05 00:00:00'),(100,'Article legacy n°96',72,'p_5f000096.760224.jpg','2021-05-14 00:00:00'),(101,'Article legacy n°97',109,NULL,'2021-05-23 00:00:00'),(102,'Article legacy n°98',26,NULL,'2021-06-01 00:00:00'),(103,'Article legacy n°99',63,NULL,'2021-06-10 00:00:00'),(104,'Article legacy n°100',100,'p_5f000100.791900.jpg','2021-06-19 00:00:00'),(105,'Article legacy n°101',17,NULL,'2021-06-28 00:00:00'),(106,'Article legacy n°102',54,NULL,'2021-07-07 00:00:00'),(107,'Article legacy n°103',91,NULL,'2021-07-16 00:00:00'),(108,'Article legacy n°104',8,'p_5f000104.823576.jpg','2021-07-25 00:00:00'),(109,'Article legacy n°105',45,NULL,'2021-08-03 00:00:00'),(110,'Article legacy n°106',82,NULL,'2021-08-12 00:00:00'),(111,'Article legacy n°107',119,NULL,'2021-08-21 00:00:00'),(112,'Article legacy n°108',36,'p_5f000108.855252.jpg','2021-08-30 00:00:00'),(113,'Article legacy n°109',73,NULL,'2021-09-08 00:00:00'),(114,'Article legacy n°110',110,NULL,'2021-09-17 00:00:00'),(115,'Article legacy n°111',27,NULL,'2021-09-26 00:00:00'),(116,'Article legacy n°112',64,'p_5f000112.886928.jpg','2021-10-05 00:00:00'),(117,'Article legacy n°113',101,NULL,'2021-10-14 00:00:00'),(118,'Article legacy n°114',18,NULL,'2021-10-23 00:00:00'),(119,'Article legacy n°115',55,NULL,'2021-11-01 00:00:00'),(120,'Article legacy n°116',92,'p_5f000116.918604.jpg','2021-11-10 00:00:00'),(121,'Article legacy n°117',9,NULL,'2021-11-19 00:00:00'),(122,'Article legacy n°118',46,NULL,'2021-11-28 00:00:00'),(123,'Article legacy n°119',83,NULL,'2021-12-07 00:00:00'),(124,'Article legacy n°120',0,'p_5f000120.950280.jpg','2021-12-16 00:00:00'),(125,'Article legacy n°121',37,NULL,'2021-12-25 00:00:00'),(126,'Article legacy n°122',74,NULL,'2022-01-03 00:00:00'),(127,'Article legacy n°123',111,NULL,'2022-01-12 00:00:00'),(128,'Article legacy n°124',28,'p_5f000124.981956.jpg','2022-01-21 00:00:00'),(129,'Article legacy n°125',65,NULL,'2022-01-30 00:00:00'),(130,'Article legacy n°126',102,NULL,'2022-02-08 00:00:00'),(131,'Article legacy n°127',19,NULL,'2022-02-17 00:00:00'),(132,'Article legacy n°128',56,'p_5f000128.1013632.jpg','2022-02-26 00:00:00'),(133,'Article legacy n°129',93,NULL,'2022-03-07 00:00:00'),(134,'Article legacy n°130',10,NULL,'2022-03-16 00:00:00'),(135,'Article legacy n°131',47,NULL,'2022-03-25 00:00:00'),(136,'Article legacy n°132',84,'p_5f000132.1045308.jpg','2022-04-03 00:00:00'),(137,'Article legacy n°133',1,NULL,'2022-04-12 00:00:00'),(138,'Article legacy n°134',38,NULL,'2022-04-21 00:00:00'),(139,'Article legacy n°135',75,NULL,'2022-04-30 00:00:00'),(140,'Article legacy n°136',112,'p_5f000136.1076984.jpg','2022-05-09 00:00:00'),(141,'Article legacy n°137',29,NULL,'2022-05-18 00:00:00'),(142,'Article legacy n°138',66,NULL,'2022-05-27 00:00:00'),(143,'Article legacy n°139',103,NULL,'2022-06-05 00:00:00'),(144,'Article legacy n°140',20,'p_5f000140.1108660.jpg','2022-06-14 00:00:00'),(145,'Article legacy n°141',57,NULL,'2022-06-23 00:00:00'),(146,'Article legacy n°142',94,NULL,'2022-07-02 00:00:00'),(147,'Article legacy n°143',11,NULL,'2022-07-11 00:00:00'),(148,'Article legacy n°144',48,'p_5f000144.1140336.jpg','2022-07-20 00:00:00'),(149,'Article legacy n°145',85,NULL,'2022-07-29 00:00:00'),(150,'Article legacy n°146',2,NULL,'2022-08-07 00:00:00'),(151,'Article legacy n°147',39,NULL,'2022-08-16 00:00:00'),(152,'Article legacy n°148',76,'p_5f000148.1172012.jpg','2022-08-25 00:00:00'),(153,'Article legacy n°149',113,NULL,'2022-09-03 00:00:00'),(154,'Article legacy n°150',30,NULL,'2022-09-12 00:00:00'),(155,'Écrou « spécial » ½ pouce — lot ☕',4,'p_5faccents.1.png','2026-10-30 15:16:53'),(156,'Photo perdue depuis 2020',1,'p_5fperdue.1.jpg','2026-10-30 15:16:53');
/*!40000 ALTER TABLE `items` ENABLE KEYS */;
UNLOCK TABLES;
/*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;
/*!40014 SET FOREIGN_KEY_CHECKS=@OLD_FOREIGN_KEY_CHECKS */;
/*!40014 SET UNIQUE_CHECKS=@OLD_UNIQUE_CHECKS */;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
/*!40111 SET SQL_NOTES=@OLD_SQL_NOTES */;

-- Dump completed on 2026-10-30 15:16:53
