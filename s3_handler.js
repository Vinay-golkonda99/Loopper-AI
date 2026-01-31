const { ECSClient, RunTaskCommand } = require("@aws-sdk/client-ecs");
const client = new ECSClient({});

exports.handler = async (event) => {
    console.log("Event:", JSON.stringify(event));

    // Support handling multiple records if needed, though usually one per event
    for (const record of event.Records) {
        const bucket = record.s3.bucket.name;
        // Handle URL encoded keys (e.g. spaces become + or %20)
        const key = decodeURIComponent(record.s3.object.key.replace(/\+/g, ' '));

        console.log(`Processing file: s3://${bucket}/${key}`);

        const params = {
            cluster: process.env.ECS_CLUSTER,
            taskDefinition: process.env.TASK_DEFINITION,
            launchType: "FARGATE",
            count: 1,
            networkConfiguration: {
                awsvpcConfiguration: {
                    subnets: process.env.SUBNETS.split(','),
                    securityGroups: [process.env.SECURITY_GROUP],
                    assignPublicIp: "DISABLED"
                }
            },
            overrides: {
                containerOverrides: [
                    {
                        name: "loopper-app-3",
                        environment: [
                            { name: "S3_BUCKET", value: bucket },
                            { name: "S3_KEY", value: key }
                        ]
                    }
                ]
            }
        };

        try {
            const command = new RunTaskCommand(params);
            const response = await client.send(command);
            console.log(`Started ECS Task: ${response.tasks[0].taskArn}`);
        } catch (error) {
            console.error("Failed to start ECS task:", error);
            throw error; // Cause Lambda to fail/retry
        }
    }

    return { statusCode: 200, body: "Done" };
};
