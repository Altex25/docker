SET NAMES utf8mb4;

CREATE DATABASE IF NOT EXISTS kennelDB
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE kennelDB;

CREATE TABLE clients (
  id INT AUTO_INCREMENT PRIMARY KEY,
  nom VARCHAR(50) NOT NULL,
  prenom VARCHAR(50) NOT NULL,
  date_naissance DATE NOT NULL,
  pseudonyme VARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE adresses (
  id INT AUTO_INCREMENT PRIMARY KEY,
  numero VARCHAR(10) NOT NULL,
  rue VARCHAR(100) NOT NULL,
  code_postal CHAR(5) NOT NULL,
  commune VARCHAR(100) NOT NULL
);

CREATE TABLE clients_adresses (
  client_id INT NOT NULL,
  adresse_id INT NOT NULL,
  PRIMARY KEY (client_id, adresse_id),
  FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE CASCADE,
  FOREIGN KEY (adresse_id) REFERENCES adresses(id) ON DELETE CASCADE
);

CREATE TABLE chiens (
  id INT AUTO_INCREMENT PRIMARY KEY,
  nom VARCHAR(50) NOT NULL,
  date_naissance DATE NOT NULL,
  race VARCHAR(50) NOT NULL,
  sterilise BOOLEAN NOT NULL DEFAULT FALSE,
  client_id INT,
  FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE SET NULL
);

CREATE TABLE chats (
  id INT AUTO_INCREMENT PRIMARY KEY,
  nom VARCHAR(50) NOT NULL,
  date_naissance DATE NOT NULL,
  race VARCHAR(50) NOT NULL,
  sterilise BOOLEAN NOT NULL DEFAULT FALSE,
  client_id INT,
  FOREIGN KEY (client_id) REFERENCES clients(id) ON DELETE SET NULL
);

INSERT INTO clients (nom, prenom, date_naissance, pseudonyme) VALUES
  ('Martin', 'Sophie', '1988-03-14', 'sophiem'),
  ('Dubois', 'Thomas', '1995-07-22', 'tomdub'),
  ('Lefèvre', 'Camille', '2001-11-05', 'cam_lef'),
  ('Moreau', 'Julien', '1979-01-30', 'jmoreau'),
  ('Petit', 'Léa', '1992-09-18', 'leapetit');

INSERT INTO adresses (numero, rue, code_postal, commune) VALUES
  ('12', 'Rue Nationale', '59000', 'Lille'),
  ('4 bis', 'Rue de Béthune', '59000', 'Lille'),
  ('27', 'Avenue de la République', '59700', 'Marcq-en-Barœul'),
  ('8', 'Rue du Molinel', '59000', 'Lille'),
  ('153', 'Boulevard Victor Hugo', '59100', 'Roubaix');

-- Un client peut avoir plusieurs adresses, une adresse peut être partagée
INSERT INTO clients_adresses (client_id, adresse_id) VALUES
  (1, 1),
  (2, 2),
  (2, 3),
  (3, 4),
  (4, 5),
  (5, 1);

INSERT INTO chiens (nom, date_naissance, race, sterilise, client_id) VALUES
  ('Rex', '2019-04-10', 'Berger allemand', TRUE, 1),
  ('Filou', '2021-06-02', 'Jack Russell', FALSE, 2),
  ('Nala', '2018-12-24', 'Labrador', TRUE, 4),
  ('Oslo', '2023-02-15', 'Border Collie', FALSE, 4),
  ('Pistache', '2020-08-08', 'Beagle', TRUE, 5);

INSERT INTO chats (nom, date_naissance, race, sterilise, client_id) VALUES
  ('Mistigri', '2017-05-19', 'Européen', TRUE, 1),
  ('Caramel', '2022-03-03', 'Maine Coon', FALSE, 3),
  ('Luna', '2020-10-11', 'Siamois', TRUE, 3),
  ('Biscotte', '2021-07-27', 'Chartreux', TRUE, 5);
