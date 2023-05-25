package com.zaremski.applenotesexporter;

import javafx.application.Application;
import javafx.fxml.FXMLLoader;
import javafx.scene.Parent;
import javafx.scene.Scene;
import javafx.scene.control.ButtonBar;
import javafx.stage.Stage;

import java.io.*;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;

import javafx.scene.control.Alert;
import javafx.scene.control.Alert.AlertType;
import javafx.scene.control.ButtonType;
public class Main extends Application {
    @Override
    public void start(Stage stage) throws IOException {
        // Create the disclaimer alert dialog
        Alert disclaimerAlert = new Alert(Alert.AlertType.INFORMATION);
        disclaimerAlert.setTitle("Disclaimer");
        disclaimerAlert.setHeaderText("By using Apple Notes Exporter you agree to these terms");
        disclaimerAlert.setContentText("Copyright (c) 2023 Konstantin Zaremski\n\n" +
                "Permission is hereby granted, free of charge, to any person obtaining a copy " +
                "of this software and associated documentation files (the \"Software\"), to deal " +
                "in the Software without restriction, including without limitation the rights " +
                "to use, copy, modify, merge, publish, distribute, sublicense, and/or sell " +
                "copies of the Software, and to permit persons to whom the Software is " +
                "furnished to do so, subject to the following conditions: \n" +
                "\n" +
                "The above copyright notice and this permission notice shall be included in all " +
                "copies or substantial portions of the Software.\n" +
                "\n" +
                "THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR " +
                "IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, " +
                "FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE " +
                "AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER " +
                "LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, " +
                "OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE " +
                "SOFTWARE.\n\n" +
                "This program makes a copy of your local Apple Notes database to a temporary directory " +
                "to lower the risk of data corruption.\n\n" +
                "At this time, please QUIT Apple Notes with ⌘ + Q");
        // Change the text of the OK button to I Agree
        ButtonType okButton = new ButtonType("I Agree", ButtonBar.ButtonData.OK_DONE);
        disclaimerAlert.getButtonTypes().setAll(okButton);

        // Show the disclaimer alert and wait for the user's response
        disclaimerAlert.showAndWait();

        // Load and display the main window if the user accepts the disclaimer
        if (disclaimerAlert.getResult() == okButton) {
            // Make a copy of the local Apple Notes database in the temporary directory
            String sourcePath = System.getProperty("user.home") + "/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite";
            String destinationPath = System.getProperty("java.io.tmpdir") + "NoteStore.sqlite";
            try {
                // Command to execute with elevated privileges
                String[] command = { "sudo", "-S", "-s", "cp", sourcePath, destinationPath };

                // Create the process and start it
                Process process = new ProcessBuilder(command).start();

                // Get the output stream of the process
                OutputStream outputStream = process.getOutputStream();

                // Write the password to the output stream
                String password = "";
                outputStream.write((password + "\n").getBytes());
                outputStream.flush();

                // Read the output from the process
                InputStream inputStream = process.getInputStream();
                InputStream errorStream = process.getErrorStream();
                BufferedReader inputReader = new BufferedReader(new InputStreamReader(inputStream));
                BufferedReader errorReader = new BufferedReader(new InputStreamReader(errorStream));

                // Print standard output
                String line;
                System.out.println("Standard Output:");
                while ((line = inputReader.readLine()) != null) {
                    System.out.println(line);
                }

                // Print error output
                System.out.println("Error Output:");
                while ((line = errorReader.readLine()) != null) {
                    System.out.println(line);
                }

                // Wait for the process to finish
                int exitCode = process.waitFor();
                System.out.println("Command exited with code: " + exitCode);

            } catch (IOException | InterruptedException e) {
                e.printStackTrace();
            }

            // Load the main scene
            FXMLLoader fxmlLoader = new FXMLLoader(Main.class.getResource("main-view.fxml"));
            Scene scene = new Scene(fxmlLoader.load(), 550, 375);
            scene.getStylesheets().add(getClass().getResource("styles.css").toExternalForm());

            // Set title and show the window
            stage.setTitle("Apple Notes Exporter 1.0.0-SNAPSHOT");
            stage.setScene(scene);
            stage.setResizable(false);
            stage.show();
        }
    }

    public static void main(String[] args) {
        launch();
    }
}