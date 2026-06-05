from http.server import BaseHTTPRequestHandler, HTTPServer

class MigrationServer(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-type", "text/html")
        self.end_headers()
        # This message simulates our application version
        self.wfile.write(b"<h1>Migration App: Version 1.0 - Running on EKS</h1>")

if __name__ == "__main__":
    web_server = HTTPServer(("0.0.0.0", 8080), MigrationServer)
    print("Server started on port 8080...")
    web_server.serve_forever()
