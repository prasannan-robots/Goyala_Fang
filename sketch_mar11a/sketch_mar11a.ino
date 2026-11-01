#include <NeoSWSerial.h>
#include <Servo.h>

NeoSWSerial sim800(4, 5); // RX = D4, TX = D5 (GSM Module)
Servo leverServo;

#define IN1 3        // Left Motor Forward
#define IN2 2        // Left Motor Backward
#define IN3 7        // Right Motor Forward
#define IN4 6        // Right Motor Backward
#define SERVO_PIN 13 // Servo Motor Pin
#define SENSOR1 A2   // First Sensor Pin (pH Sensor)
#define SENSOR2 A3   // Second Sensor Pin (Moisture Sensor)

// Phone running the Saga app. Readings are sent here by SMS.
#define CONTROLLER_PHONE "+919840215374"

void setup() {
    Serial.begin(9600);
    sim800.begin(9600); // Initialize GSM Module Communication

    pinMode(IN1, OUTPUT);
    pinMode(IN2, OUTPUT);
    pinMode(IN3, OUTPUT);
    pinMode(IN4, OUTPUT);

    leverServo.attach(SERVO_PIN);
    stopMotors();
}

void loop() {
    if (sim800.available()) {
        String message = sim800.readString(); // Read incoming SMS

        if (message.indexOf("Start") != -1) {
            moveForward(); // Move robot forward for 8 seconds
            delay(8000);
            stopMotors();
            checkSensors();
        }
    }
}

void moveForward() {
    digitalWrite(IN1, HIGH);
    digitalWrite(IN2, LOW);
    digitalWrite(IN3, HIGH);
    digitalWrite(IN4, LOW);
}

void stopMotors() {
    digitalWrite(IN1, LOW);
    digitalWrite(IN2, LOW);
    digitalWrite(IN3, LOW);
    digitalWrite(IN4, LOW);
}

void checkSensors() {
    leverServo.write(90); // Move servo
    delay(5000);
    
    int phValue = analogRead(SENSOR1);
    int moistureValue = analogRead(SENSOR2);

    leverServo.write(0); // Move servo back to original position

    // Format parsed by the app (delta/lib/logic/robot_protocol.dart):
    //   S:Lat:<lat>,Lng:<lng>,Sensor:<pH>-<EC>-<moisture>
    // The NPK model needs pH, EC and moisture; this board has no EC sensor
    // yet, so the app shows the readings but cannot predict NPK from them.
    // TODO: replace the fixed coordinates with a GPS fix and calibrate the
    // raw analogRead() values into pH / moisture units.
    String result = "S:Lat:12.820030,Lng:80.039433,Sensor:" + String(phValue) + "-" + String(moistureValue);
    sendSMS(result);
}

void sendSMS(String message) {
    sim800.println("AT+CMGF=1"); // Set SMS mode
    delay(1000);
    sim800.println("AT+CMGS=\"" CONTROLLER_PHONE "\""); // Set recipient number
    delay(1000);
    sim800.println(message);
    delay(1000);
    sim800.write(26); // End SMS with Ctrl+Z
    delay(1000);
}