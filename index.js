const { SQSClient, SendMessageCommand } = require("@aws-sdk/client-sqs");
const client = new SQSClient({});

exports.handler = async (event) => {
    const queueUrl = process.env.QUEUE_URL;

    // API Gateway payload structure
    const body = event.body || "{}";

    const command = new SendMessageCommand({
        QueueUrl: queueUrl,
        MessageBody: body,
        // Required for FIFO queues. 
        // Using a static ID means all messages are processed in strict order (Sequence).
        // If you want parallel processing per customer/ID, change this to dynamic value (e.g. body.userId).
        MessageGroupId: "default",
    });

    try {
        const response = await client.send(command);
        return {
            statusCode: 200,
            body: JSON.stringify({
                message: "Message sent to FIFO SQS",
                messageId: response.MessageId
            }),
        };
    } catch (err) {
        console.error("SQS Send Error:", err);
        return {
            statusCode: 500,
            body: JSON.stringify({
                message: "Failed to send message",
                error: err.message
            }),
        };
    }
};
