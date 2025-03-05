"""Common python utils"""
def make_menu(options):
    print("Veuillez choisir une option :")
    for i, option in enumerate(options, start=0):
        print(f"{i}. {option}")
    while True:
        try:
            choix = int(input("Votre choix (numéro) : "))
            if 0 <= choix <= len(options):
                return choix
            else:
                print("Choix invalide, merci de réessayer.")
        except ValueError:
            print("Veuillez entrer un nombre valide.")