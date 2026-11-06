-- Выполняется один раз при создании тома с базой.
-- Схемы создаём заранее: Liquibase сам схему не создаёт, а свою служебную таблицу кладёт в неё же.
CREATE SCHEMA IF NOT EXISTS account;
CREATE SCHEMA IF NOT EXISTS pricing;
CREATE SCHEMA IF NOT EXISTS payment;
CREATE SCHEMA IF NOT EXISTS history;
CREATE SCHEMA IF NOT EXISTS biller;
CREATE SCHEMA IF NOT EXISTS autopayments;
