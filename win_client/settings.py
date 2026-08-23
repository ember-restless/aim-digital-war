# AIM 设置（快捷键等），存 win_client/settings.json
import json
import os

KEYS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'settings.json')

DEFAULTS = {
    'move': '1',
    'attack': '2',
    'devour': '3',
    'split': '4',
    'cancel': 'escape',
}


def load():
    try:
        with open(KEYS_FILE, encoding='utf-8') as f:
            d = json.load(f)
        out = dict(DEFAULTS)
        out.update({k: v for k, v in d.items() if k in DEFAULTS})
        return out
    except Exception:
        return dict(DEFAULTS)


def save(keys):
    try:
        with open(KEYS_FILE, 'w', encoding='utf-8') as f:
            json.dump({k: v for k, v in keys.items() if k in DEFAULTS}, f, ensure_ascii=False, indent=2)
    except Exception:
        pass
