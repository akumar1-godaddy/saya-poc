import os
import psycopg2
import logging

# Set up logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Lambda environment variables
DB_ENDPOINT = os.environ['DB_ENDPOINT']
DB_PORT = os.environ['DB_PORT']
DB_NAME = os.environ['DB_NAME']
DB_USER = os.environ['DB_USER']
DB_PASSWORD = os.environ['DB_PASSWORD']

def lambda_handler(event, context):
    try:
        # Connect to the RDS database using psycopg2
        connection = psycopg2.connect(
            host=DB_ENDPOINT,
            port=DB_PORT,
            database=DB_NAME,
            user=DB_USER,
            password=DB_PASSWORD
        )

        cursor = connection.cursor()
        logger.info("Connected to the database")

        # Execute a simple query
        cursor.execute("SELECT 1;")
        result = cursor.fetchone()
        logger.info(f"Query Result: {result}")

        # Close the cursor and connection
        cursor.close()
        connection.close()
        logger.info("Connection closed successfully")
        return {
            'statusCode': 200,
            'body': 'Database connection and query successful'
        }

    except Exception as e:
        logger.error(f"Error connecting to the database: {e}")
        return {
            'statusCode': 500,
            'body': f"Failed to connect to the database: {str(e)}"
        }
