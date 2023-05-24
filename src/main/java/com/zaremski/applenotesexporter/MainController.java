package com.zaremski.applenotesexporter;

import javafx.fxml.FXML;
import javafx.fxml.Initializable;
import javafx.scene.control.ComboBox;
import javafx.scene.control.Label;
import javafx.collections.ObservableList;
import javafx.collections.FXCollections;


import java.io.IOException;
import java.net.URL;
import java.util.ResourceBundle;

public class MainController implements Initializable {
    @FXML
    private Label welcomeText;
    @FXML
    private ComboBox accountSelectorDropdown;


    @FXML
    protected void onHelloButtonClick() {
        welcomeText.setText("Welcome to JavaFX Application!");
    }

    /**
     * Handle the clicking of the "MIT License" hyperlink in the footer.
     * Opens "https://raw.githubusercontent.com/kzaremski/apple-notes-exporter/main/LICENSE" using the default browser (MacOS)
     */
    @FXML
    protected void handleLicenseLinkClick() {
        try {
            Runtime.getRuntime().exec("open https://raw.githubusercontent.com/kzaremski/apple-notes-exporter/main/LICENSE");
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
    }

    @Override
    public void initialize(URL url, ResourceBundle resourceBundle) {
        accountSelectorDropdown.setPromptText("Select source Apple Notes account from this list");
        ObservableList<String> accounts =
                FXCollections.observableArrayList(
                        "Option 1",
                        "Option 2",
                        "Option 3"
                );
        accountSelectorDropdown.setItems(accounts);


    }
}