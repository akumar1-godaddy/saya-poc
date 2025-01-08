import boto3
import json
import os

def assume_role(role_arn, session_name):
    """
    Assumes a role in another AWS account and returns temporary credentials.
    """
    try:
        sts_client = boto3.client('sts')
        assumed_role_object = sts_client.assume_role(
            RoleArn=role_arn,
            RoleSessionName=session_name
        )
        credentials = assumed_role_object['Credentials']
        return credentials
    except Exception as e:
        print(f"Error assuming role: {str(e)}")
        return None


def scan_dynamodb_table_with_assumed_role(table_name, credentials):
    """
    Scans a DynamoDB table using assumed role credentials.
    """
    try:
        # Use the temporary credentials to create a session
        dynamodb = boto3.resource(
            'dynamodb',
            region_name='us-west-2',
            aws_access_key_id=credentials['AccessKeyId'],
            aws_secret_access_key=credentials['SecretAccessKey'],
            aws_session_token=credentials['SessionToken']
        )

        # Reference the DynamoDB table
        table = dynamodb.Table(table_name)

        # Perform the Scan operation
        print("Trying to scan DynamoDB table with assumed role...")
        response = table.scan()

        # Get the items returned in the scan
        items = response.get('Items', [])

        # Handle pagination if the result is truncated
        while 'LastEvaluatedKey' in response:
            response = table.scan(ExclusiveStartKey=response['LastEvaluatedKey'])
            items.extend(response.get('Items', []))

        print(f"Scan successful. Retrieved {len(items)} items.")
        print(json.dumps(items, indent=2))

        return {
            'statusCode': 200,
            'body': json.dumps(items)
        }

    except Exception as e:
        print(f"Error scanning table: {e}")
        return {
            'statusCode': 500,
            'body': json.dumps(f"Error scanning table: {str(e)}")
        }


def lambda_handler(event, context):
    # ARN of the role to assume in Account B
    role_arn = 'arn:aws:iam::911167911228:role/sresharedc-custom-dynamo-vpce-lambda'

    # Session name for STS
    session_name = 'DynamoDBAssumeRoleSession'

    # Assume the role in Account B
    credentials = assume_role(role_arn, session_name)

    if credentials is None:
        return {
            'statusCode': 500,
            'body': 'Error assuming role'
        }

    # The DynamoDB table name in Account B
    table_name = 'user-insight-registry'

    # Scan the DynamoDB table using the assumed role credentials
    return scan_dynamodb_table_with_assumed_role(table_name, credentials)


if __name__ == '__main__':
    lambda_handler(None, None)
