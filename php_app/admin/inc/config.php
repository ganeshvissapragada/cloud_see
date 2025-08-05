<?php
// Error Reporting Turn On
ini_set('error_reporting', E_ALL);

// Setting up the time zone
date_default_timezone_set('Asia/Dubai');

// Host Name
$dbhost = 'localhost';

// Database Name — change if your DB is different
$dbname = 'ecommerce_db';

// Database Username
$dbuser = 'root';

// Database Password — MAMP default is 'root'
$dbpass = 'root';

// Defining base url
define("BASE_URL", "http://localhost:8888/PHP-MySQL-ecommerce-website-master/");
define("ADMIN_URL", BASE_URL . "admin" . "/");

try {
    $pdo = new PDO("mysql:host={$dbhost};dbname={$dbname}", $dbuser, $dbpass);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
} catch (PDOException $exception) {
    echo "Connection error: " . $exception->getMessage();
}
