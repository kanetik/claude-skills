from client import fetch


def restore(url):
    data = fetch(url, timeout=30)
    return data
