import math
import RPi.GPIO as GPIO
import time
import threading
import os
from flask import Flask, render_template, request, jsonify
import webbrowser

LED_PINS = [5, 8, 10]
SERVO_PINS = [12, 32, 33]
ULTRASONIC_SENSORS = [(19, 21), (22, 23), (24, 26)]

MORSE_CODE = {
    'A': '.-', 'B': '-...', 'C': '-.-.', 'D': '-..', 'E': '.',
    'F': '..-.', 'G': '--.', 'H': '....', 'I': '..', 'J': '.---',
    'K': '-.-', 'L': '.-..', 'M': '--', 'N': '-.', 'O': '---',
    'P': '.--.', 'Q': '--.-', 'R': '.-.', 'S': '...', 'T': '-',
    'U': '..-', 'V': '...-', 'W': '.--', 'X': '-..-', 'Y': '-.--',
    'Z': '--..',
    '1': '.----', '2': '..---', '3': '...--', '4': '....-', '5': '.....',
    '6': '-....', '7': '--...', '8': '---..', '9': '----.', '0': '-----',
    ' ': ' '
}

servo_duty_cycles = {}
servo_directions = {}
servo_coordinates = {}

center_x = 0
center_y = 0
servo1_x = 0
servo1_y = 0
target_x = 0
target_y = 0
servo_index = 0

targeted_mode = False

GPIO.setmode(GPIO.BOARD)
GPIO.setwarnings(False)

for pin in LED_PINS:
    GPIO.setup(pin, GPIO.OUT)

servos = {}
for pin in SERVO_PINS:
    GPIO.setup(pin, GPIO.OUT)
    servo = GPIO.PWM(pin, 50)
    servo.start(0)
    servos[pin] = servo
    servo_duty_cycles[pin] = 7.5

for trigger, echo in ULTRASONIC_SENSORS:
    GPIO.setup(trigger, GPIO.OUT)
    GPIO.setup(echo, GPIO.IN)
    GPIO.output(trigger, False)

def transmit_morse(pin, message):
    for char in message:
        if char == " ":
            time.sleep(1.2)
        code = MORSE_CODE.get(char.upper(), '')
        for symbol in code:
            if symbol == '.':
                GPIO.output(pin, True)
                time.sleep(0.8)
                GPIO.output(pin, False)
                time.sleep(0.3)
            elif symbol == '-':
                GPIO.output(pin, True)
                time.sleep(0.3)
                GPIO.output(pin, False)
                time.sleep(0.3)
        time.sleep(0.6)

def caesar_cipher_encrypt(text, key):
    encrypted_text = []
    for char in text:
        if char.isupper():
            encrypted_text.append(chr((ord(char) - 65 + key) % 26 + 65))
        elif char.islower():
            encrypted_text.append(chr((ord(char) - 97 + key) % 26 + 97))
        else:
            encrypted_text.append(char)
    return ''.join(encrypted_text)

shift_key = 3

def set_servo_angle(servo, servo_pin, angle):
    global servo_duty_cycles
    duty_cycle = ((angle / 18) + 10) / 2
    duty_cycle = max(2.5, min(12.5, duty_cycle))  # Keep duty cycle within safe limits
    servo.ChangeDutyCycle(duty_cycle)
    servo_duty_cycles[servo_pin] = duty_cycle
    time.sleep(0.5)
    servo.ChangeDutyCycle(0)

def measure_distance(trigger_pin, echo_pin):
    GPIO.output(trigger_pin, True)
    time.sleep(0.00001)
    GPIO.output(trigger_pin, False)

    start_time = time.time()
    stop_time = time.time()

    while GPIO.input(echo_pin) == 0:
        start_time = time.time()
        if time.time() - start_time > 0.01:
            return None

    while GPIO.input(echo_pin) == 1:
        stop_time = time.time()
        if stop_time - start_time > 0.02:
            return None

    time_elapsed = stop_time - start_time
    distance = (time_elapsed * 34300) / 2
    return distance

def broadcast_message(message):
    threads = []
    def transmit_thread(pin):
        transmit_morse(pin, message)
    for pin in LED_PINS:
        thread = threading.Thread(target=transmit_thread, args=(pin,))
        threads.append(thread)
        thread.start()
    for thread in threads:
        thread.join()

def cartesian_to_polar(x, y):
    angle = math.degrees(math.atan2(y, x)) % 360
    return angle

def calculate_servo_coordinates(center_x, center_y, servo1_x, servo1_y):
    servo1_angle = cartesian_to_polar(servo1_x - center_x, servo1_y - center_y)
    servo2_angle = (servo1_angle + 120) % 360
    servo3_angle = (servo1_angle - 120) % 360
    r = math.sqrt((servo1_x - center_x)*2 + (servo1_y - center_y)*2)
    servo2_x = center_x + r * math.cos(math.radians(servo2_angle))
    servo2_y = center_y + r * math.sin(math.radians(servo2_angle))
    servo3_x = center_x + r * math.cos(math.radians(servo3_angle))
    servo3_y = center_y + r * math.sin(math.radians(servo3_angle))
    return {
        SERVO_PINS[0]: (servo1_x, servo1_y),
        SERVO_PINS[1]: (servo2_x, servo2_y),
        SERVO_PINS[2]: (servo3_x, servo3_y)
    }

def find_closest_servo(target_x, target_y, servo_coordinates):
    closest_servo = None
    min_distance = float('inf')
    for servo_pin, (servo_x, servo_y) in servo_coordinates.items():
        distance = math.sqrt((servo_x - target_x)*2 + (servo_y - target_y)*2)
        if distance < min_distance:
            min_distance = distance
            closest_servo = servo_pin
    return closest_servo

def calculate_turn_angle(center_x, center_y, target_x, target_y, servo_x, servo_y):
    d1 = math.sqrt((target_x - center_x) ** 2 + (target_y - center_y) ** 2)
    d2 = math.sqrt((servo_x - center_x) ** 2 + (servo_y - center_y) ** 2)
    d3 = math.sqrt((servo_x - target_x) ** 2 + (servo_y - target_y) ** 2)

    if d1 * d2 != 0:
        cos_theta = (d1*2 + d22 - d3*2) / (2 * d1 * d2)
        cos_theta = max(-1, min(1, cos_theta))
        angle = math.degrees(math.acos(cos_theta))

        # Determine if the target is to the left or right of the servo
        cross_product = (servo_x - center_x) * (target_y - center_y) - (servo_y - center_y) * (target_x - center_x)
        
        if cross_product < 0:
            angle = angle  # Turn left
        else:
            angle = -angle   # Turn right
        
        return angle
    return 0

add_logs = []  # List to store log messages

def add_log(message):
    add_logs.append(message)

app = Flask(_name_)
selecting_center = True

@app.route('/')
def index():
    global add_logs
    add_log("Select center coordinate")
    return render_template('map.html', add_logs=add_logs)

initial_setup_done = False

@app.route('/update_coords', methods=['POST'])
def update_coords():
    global center_x, center_y, servo1_x, servo1_y, selecting_center, servo_coordinates, initial_setup_done

    # If initial setup is already complete, ignore further coordinate updates.
    if initial_setup_done:
        add_log("Initial setup complete. Ignoring additional map clicks.")
        return jsonify(success=True, message="Initial setup complete, ignoring further coordinate updates.")

    data = request.get_json()
    lat, lng = data.get("lat"), data.get("lng")

    if selecting_center:
        center_x, center_y = float(lat), float(lng)
        add_log(f"Center Coordinates set: {center_x}, {center_y}")
        selecting_center = False
        add_log("Select first servo coordinate")
    else:
        servo1_x, servo1_y = float(lat), float(lng)
        add_log(f"First Servo Coordinates set: {servo1_x}, {servo1_y}")
        servo_coordinates = calculate_servo_coordinates(center_x, center_y, servo1_x, servo1_y)
        add_log("Select mode")
        # Mark initial setup as done
        initial_setup_done = True

    return jsonify(success=True)

@app.route('/update_target_coords', methods=['POST'])
def update_target_coords():
    global target_x, target_y, servo_index
    data = request.json
    target_x = float(data['lat'])
    target_y = float(data['lng'])

    add_log(f"Target coordinates received: ({target_x}, {target_y})")

    closest_servo = find_closest_servo(target_x, target_y, servo_coordinates)
    if closest_servo is not None:
        servo_x, servo_y = servo_coordinates[closest_servo]
        target_angle = calculate_turn_angle(center_x, center_y, target_x, target_y, servo_x, servo_y)
        set_servo_angle(servos[closest_servo], closest_servo, target_angle)

        servo_index = SERVO_PINS.index(closest_servo)
        trigger, echo = ULTRASONIC_SENSORS[servo_index]
        distance = measure_distance(trigger, echo)

        if distance is not None:
            add_log(f"Distance to target: {distance:.2f} cm")
        else:
            add_log("No distance reading (timeout or out of range).")

        if distance is not None and distance < 20:
            add_log("Obstacle detected! Adjusting servo angle by 5 degrees.")
            current_angle = (servo_duty_cycles[closest_servo] * 2 - 10) * 18
            new_angle = min(180, current_angle + 5)
            set_servo_angle(servos[closest_servo], closest_servo, new_angle)

    add_log("Enter Message")

    return jsonify(success=True)

@app.route('/log', methods=['GET'])
def get_logs():
    return jsonify(add_logs)

@app.route('/submit_choice', methods=['POST'])
def submit_choice():
    global servo_coordinates, center_x, center_y, target_x, target_y, choice, targeted_mode, servos, servo_duty_cycles

    data = request.get_json()
    choice = data.get("choice")

    if choice == '1':  # Broadcast Mode
        for pin, servo in servos.items():
            set_servo_angle(servo, pin, 0)

        for trigger, echo in ULTRASONIC_SENSORS:
            distance = measure_distance(trigger, echo)
            add_log(f"Distance: {distance:.2f} cm" if distance is not None else "No reading (timeout or out of range).")

            if distance is not None and distance < 20:
                add_log("Obstacle detected! Turning servos by 5 degrees.")
                for pin, servo in servos.items():
                    current_angle = (servo_duty_cycles[pin] * 2 - 10) * 18
                    new_angle = current_angle + 5
                    set_servo_angle(servo, pin, new_angle)
        
        add_log("Enter the message")

    elif choice == '2':  # Targeted Mode
        targeted_mode = True
        add_log("Targeted Mode activated. Waiting for target coordinates...")

    elif choice == '3':  # Exit
        add_log("Exiting application...")
        os.system("pkill -f flask")  # Kill Flask process
        return jsonify(success=True), 200
    else:
        add_log("Invalid choice received.")

    return jsonify(success=True)

@app.route('/submit_message', methods=['POST'])
def submit_message():
    global servo_index
    data = request.get_json()
    message = data.get("message")

    if message:
        encrypted_message = caesar_cipher_encrypt(message, shift_key)
        add_log(f"Encrypted Message: {encrypted_message}")
    else:
        add_log("No message entered.")

    if choice == '1':  # Broadcast Mode
        broadcast_message(encrypted_message)
        add_log(f"Broadcast Message Sent: \"{message}\"")
    
    elif choice == '2':  # Targeted Mode
        if target_x == 0 and target_y == 0:
            return jsonify(success=False, error="Target coordinates not set"), 400

        transmit_morse(LED_PINS[servo_index], encrypted_message)
        add_log(f"Targeted Message Sent to ({target_x}, {target_y}): \"{message}\"")

    return jsonify(success=True)

def run_flask():
    try:
        app.run(host="0.0.0.0", port=5000, debug=False)
    finally:
        GPIO.cleanup()  

if _name_ == "_main_":
    flask_thread = threading.Thread(target=run_flask, daemon=True)
    flask_thread.start()
    time.sleep(1)
    webbrowser.open("http://localhost:5000")
    flask_thread.join()