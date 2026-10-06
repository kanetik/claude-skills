from client import fetch


def pull(url):
    return fetch(url, timeout=30)
