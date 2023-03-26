import requests
import argparse
import difflib

parser = argparse.ArgumentParser(description='Test OneEqualOne SQLi')
parser.add_argument("url", help='URL to test')
parser.add_argument('--diff',action="store_true", help='Print Difference between normal request and forged request')
args = parser.parse_args()

url=args.url
payload= "'--"

forgedUrl=url+payload
r=requests.get(url)
rForged=requests.get(forgedUrl)
print("Normal Request Status Code " + str(r.status_code))
print("Forged Request Status Code " + str(rForged.status_code))
print("Size of Normal Request " + str(len(r.content)))
print("Size of Forged Request " + str(len(rForged.content)))
if args.diff:
    out =  r.text.splitlines()
    outForged = rForged.text.splitlines()
    for diff in difflib.context_diff(out, outForged):
        print(diff)
