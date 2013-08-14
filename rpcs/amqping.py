import argparse
import pika

"""
AMQP test script.
This script takes AMQP connection details and credentials and attempts to connect.
If an AMQP connection is established a success message is printed, otherwise an
eception is printed.
"""

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('-u', '--user')
    parser.add_argument('-p', '--password')
    parser.add_argument('-v', '--vhost')
    parser.add_argument('-H', '--host', default="localhost", help="Defaults to localhost")
    parser.add_argument('-P', '--port', default=5672, type=int, help="Defaults to 5672")
    options = parser.parse_args()
    amqp_connect(options.user, options.password, options.vhost, options.host, options.port)

def amqp_connect(user,password,vhost,host,port):
    credentials = pika.PlainCredentials(user, password)
    parameters = pika.ConnectionParameters(credentials=credentials,
                                           virtual_host="/%s"%vhost,
                                           host=host,
                                           port=port)
    connection = pika.SelectConnection(parameters, on_connected)
    try:
        # Loop so we can communicate with RabbitMQ
        connection.ioloop.start()
    except KeyboardInterrupt:
        # Gracefully close the connection
        connection.close()
        # Loop until we're fully closed, will stop on its own
        connection.ioloop.start()


def on_connected(connection):
    """ Connection callback """
    print "Successfully opened AMQP connection."
    connection.close()

if __name__ == "__main__":
    main()
