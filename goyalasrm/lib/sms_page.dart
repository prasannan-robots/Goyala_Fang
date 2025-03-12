import 'package:flutter/material.dart';
import 'package:another_telephony/telephony.dart';

class SmsPage extends StatefulWidget {
  @override
  _SmsPageState createState() => _SmsPageState();
}

class _SmsPageState extends State<SmsPage> {
  // Initialize communication (e.g., Bluetooth)
  String receivedMessage = "";
  final Telephony telephony = Telephony.instance;
  //  final messenger = FlutterBackgroundMessenger();

  @override
  void initState() {
    super.initState();
    // Set up communication listener
    //  sendSMS();
    //telephony.sendSms(to: "+919840215374", message: "This is the way!");
  }
  // void _sendSMS(String message, List<String> recipents) async {
  //  String _result = await sendSMS(message: message, recipients: recipents)
  //         .catchError((onError) {
  //       print(onError);
  //     });
  // print(_result);
  // }
  // Future<void> sendSMS() async {
  //   try {
  //     final success = await messenger.sendSMS(
  //       phoneNumber: '+917825033051',
  //       message: 'Hello from Flutter Background Messenger!',
  //     );

  //     if (success) {
  //       print('SMS sent successfully');
  //     } else {
  //       print('Failed to send SMS');
  //     }
  //   } catch (e) {
  //     print('Error sending SMS: $e');
  //   }
  // }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('GSM SMS Controller')),
      body: Column(
        children: [
          Text('Received: $receivedMessage'),
          TextField(
            onSubmitted: (text) {
              //sendSMS();
            },
            decoration: InputDecoration(labelText: 'Enter message'),
          ),
        ],
      ),
    );
  }
}
