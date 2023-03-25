import requests

url=""
payload= "'--"

forgedUrl=url+payload

r=requests.get(forgedUrl)
print(r.status_code)
out = r.content
print(out)
