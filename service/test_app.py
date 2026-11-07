import os
import tempfile
import unittest
from unittest.mock import patch

from app import app


class ServiceTestCase(unittest.TestCase):
    def setUp(self):
        self.client = app.test_client()

    def test_root_uses_environment(self):
        with patch.dict(os.environ, {"APP_NAME": "grader", "VERSION": "9.9.9"}):
            response = self.client.get("/")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json["app"], "grader")
        self.assertEqual(response.json["version"], "9.9.9")
        self.assertTrue(response.json["pod"])

    def test_healthz(self):
        response = self.client.get("/healthz")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json, {"status": "ok"})

    def test_projected_file_reflects_configmap_updates(self):
       with tempfile.TemporaryDirectory() as temp_dir:
           config_path = os.path.join(temp_dir, "APP_NAME")
    
           with open(config_path, "w", encoding="utf-8") as config_file:
               config_file.write("from-configmap")
    
           with patch.dict(
               os.environ,
               {
                   "APP_NAME": "from-env",
                   "APP_NAME_FILE": config_path,
               },
           ):
               response = self.client.get("/")
    
       self.assertEqual(response.status_code, 200)
       self.assertEqual(response.json["app"], "from-configmap")
    

if __name__ == "__main__":
    unittest.main()
