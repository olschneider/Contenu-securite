"""
Library for MS Graph
Dépendances: 
msal
"""
from msal import PublicClientApplication
import common

class MSGraph:
    """
    Classe pour interroger MSGraph.
    In:ClientId, TenantId
    """
    OAUTH_AUTHORITY = "https://login.microsoftonline.com/"
    def __init__(self, client_id, tenant_id):
        self.client_id = client_id
        self.tenant_id = tenant_id
        self.app = None
        self.access_token = None

    def app_initialization(self,login,scopes):
        result = None
        self.app = PublicClientApplication(self.client_id,authority=self.OAUTH_AUTHORITY+self.tenant_id)
        accounts = self.app.get_accounts()
        if accounts:
            tmp_dict = [ a["username"] for a in accounts.values() if "username" in a ]
            choix = common.make_menu(tmp_dict)
            result = self.app.acquire_token_silent(scopes=scopes, account=accounts[choix])
        else:
            print("aucun compte disponible pour cette application")
            result = self.app.acquire_token_interactive(scopes=scopes, login_hint=login)
            if "access_token" in result:
                print(result["access_token"])
            else:
                print(result.get("error"))
                print(result.get("error_description"))
                print(result.get("correlation_id"))
        return result
    
