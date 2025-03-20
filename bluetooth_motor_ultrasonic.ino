#include <SoftwareSerial.h>

// Bluetooth module pins
SoftwareSerial bluetooth(10, 11); // RX, TX

// Motor driver pins
const int ENA = 9;  // Enable pin for motor A
const int IN1 = 8;  // Input 1 for motor A
const int IN2 = 7;  // Input 2 for motor A
const int ENB = 6;  // Enable pin for motor B
const int IN3 = 5;  // Input 1 for motor B
const int IN4 = 4;  // Input 2 for motor B

// Ultrasonic sensor pins
const int trigPin = 3;
const int echoPin = 2;

// Variables
bool isMoving = false;

void setup() {
  // Initialize serial communication
  bluetooth.begin(9600);
  Serial.begin(9600);

  // Motor pins as output
  pinMode(ENA, OUTPUT);
  pinMode(IN1, OUTPUT);
  pinMode(IN2, OUTPUT);
  pinMode(ENB, OUTPUT);
  pinMode(IN3, OUTPUT);
  pinMode(IN4, OUTPUT);

  // Ultrasonic sensor pins
  pinMode(trigPin, OUTPUT);
  pinMode(echoPin, INPUT);

  // Stop motors initially
  stopMotors();
}

void loop() {
  // Check for Bluetooth commands
  if (bluetooth.available()) {
    String command = bluetooth.readString();
    command.trim();

    if (command == "start") {
      isMoving = true;
    } else if (command == "stop") {
      isMoving = false;
      stopMotors();
    }
  }

  // If moving, check for obstacles
  if (isMoving) {
    if (detectObstacle()) {
      stopMotors();
      isMoving = false;
      bluetooth.println("Obstacle detected! Stopping.");
    } else {
      moveForward();
    }
  }
}

// Function to move the robot forward
void moveForward() {
  digitalWrite(IN1, HIGH);
  digitalWrite(IN2, LOW);
  digitalWrite(IN3, HIGH);
  digitalWrite(IN4, LOW);
  analogWrite(ENA, 150); // Adjust speed
  analogWrite(ENB, 150); // Adjust speed
}

// Function to stop the motors
void stopMotors() {
  digitalWrite(IN1, LOW);
  digitalWrite(IN2, LOW);
  digitalWrite(IN3, LOW);
  digitalWrite(IN4, LOW);
  analogWrite(ENA, 0);
  analogWrite(ENB, 0);
}

// Function to detect obstacles using the ultrasonic sensor
bool detectObstacle() {
  digitalWrite(trigPin, LOW);
  delayMicroseconds(2);
  digitalWrite(trigPin, HIGH);
  delayMicroseconds(10);
  digitalWrite(trigPin, LOW);

  long duration = pulseIn(echoPin, HIGH);
  long distance = duration * 0.034 / 2; // Convert to cm

  return distance < 20; // Obstacle detected if distance < 20 cm
}
