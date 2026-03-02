from jira import JIRA
import os

Gorgid = os.getenv('ORGID','ORGID')
Guser = os.getenv('USER','sales@grandtst')
Gapikey = os.getenv('APIKEY','make_an_api_key')
jira = JIRA(
    server="https://your-domain.atlassian.net",
	orgid=Gorgid,
    basic_auth=(Guser,Gapikey)
)

print(jira.current_user())
