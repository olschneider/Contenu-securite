"""
script test msgraph
dépendances: python-dotenv

"""

import sys
import os 
lib_path = os.path.join(os.path.dirname(__file__), '..', 'my_lib')
if lib_path not in sys.path:
    sys.path.append(lib_path)
    print(sys.path)
from dotenv import load_dotenv
from ms_lib import MSGraph

load_dotenv()

def main() -> int:
    """Test"""
    ID_CLIENT = os.getenv("ID_CLIENT")
    ID_TENANT = os.getenv("ID_TENANT")
    SCOPES = ["AuditLog.Read.All","ChangeManagement.Read.All"]
    app = MSGraph(ID_CLIENT,ID_TENANT)
    login = input("Entrer le nom de compte Entra ID à utiliser:")
    myapp = app.app_initialization(login,SCOPES)
    print(myapp)
    ret = 0
    return ret

if __name__ == '__main__':
    sys.exit(main())