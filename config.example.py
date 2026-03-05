# config.example.py — copier en config.py et remplir les valeurs
# NE PAS committer config.py (contient des secrets)

BOT_TOKEN  = "VOTRE_TOKEN_ICI"
CHANNEL_ID = 123456789012345678  # int, pas string

# Canaux à purger au démarrage du bot (ajouter d'autres IDs si besoin)
CHANNELS_TO_CLEAN = [
    CHANNEL_ID,
    # 123456789012345678,  # autre canal si besoin
]

DISCORD_UPDATE_INTERVAL = 60  # secondes entre chaque édition du message
