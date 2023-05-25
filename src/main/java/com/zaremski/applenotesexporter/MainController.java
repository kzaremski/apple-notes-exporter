package com.zaremski.applenotesexporter;

import javafx.event.ActionEvent;
import javafx.fxml.FXML;
import javafx.fxml.FXMLLoader;
import javafx.fxml.Initializable;
import javafx.scene.Node;
import javafx.scene.Parent;
import javafx.scene.Scene;
import javafx.scene.control.ComboBox;
import javafx.scene.control.Label;
import javafx.collections.ObservableList;
import javafx.collections.FXCollections;
import javafx.scene.control.RadioButton;
import javafx.scene.control.ToggleGroup;
import javafx.stage.DirectoryChooser;
import javafx.stage.FileChooser;
import javafx.stage.Modality;
import javafx.stage.Stage;

import java.io.File;
import java.io.IOException;
import java.net.URL;
import java.util.ResourceBundle;

public class MainController implements Initializable {
    @FXML
    private Label welcomeText;
    @FXML
    private ComboBox accountSelectorDropdown;
    @FXML
    private RadioButton formatRadioButton_HTML;
    @FXML
    private RadioButton formatRadioButton_PDF;
    @FXML
    private RadioButton formatRadioButton_RTFD;
    @FXML
    private RadioButton formatRadioButton_MD;
    @FXML
    private RadioButton formatRadioButton_TXT;
    @FXML
    private Label outputDirectoryLabel;

    private File outputDirectory = null;

    private void updateOutputDirectory(File outputDirectory) {
        // Update the data field of the controller if the new directory is not null
        if (outputDirectory != null) this.outputDirectory = outputDirectory;

        // Update the text label
        if (outputDirectory == null) outputDirectoryLabel.setText("Select output file location.");
        else outputDirectoryLabel.setText(outputDirectory.toPath().toString() + "/");
    }

    @FXML
    protected void startExport(ActionEvent event) throws IOException {
        FXMLLoader fxmlLoader = new FXMLLoader(getClass().getResource("progress-view.fxml"));
        Parent root = fxmlLoader.load();

        Stage progressStage = new Stage();
        progressStage.setTitle("Export Progress");
        progressStage.setScene(new Scene(root, 400, 60));
        progressStage.initModality(Modality.WINDOW_MODAL);
        progressStage.initOwner(((Node) event.getSource()).getScene().getWindow());
        progressStage.setResizable(false);

        progressStage.showAndWait();
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

    /**
     * Handle the clicking of the choose button for the output directory.
     * @param event - Event fired by the clicking of the button.
     */
    @FXML
    private void handleOutputLocationChooseButton(ActionEvent event) {
        // Let the user select the output directory
        DirectoryChooser directoryChooser = new DirectoryChooser();
        directoryChooser.setTitle("Select Folder");

        File selectedFolder = directoryChooser.showDialog(null);

        // Update the output directory
        updateOutputDirectory(selectedFolder);
    }

    @Override
    public void initialize(URL url, ResourceBundle resourceBundle) {
        // Create the list of accounts
        accountSelectorDropdown.setPromptText("Select source Apple Notes account from this list");
        ObservableList<String> accounts =
                FXCollections.observableArrayList(
                        "Option 1",
                        "Option 2",
                        "Option 3"
                );
        accountSelectorDropdown.setItems(accounts);

        // Configure the type radio buttons
        ToggleGroup toggleGroup = new ToggleGroup();
        formatRadioButton_HTML.setToggleGroup(toggleGroup);
        formatRadioButton_PDF.setToggleGroup(toggleGroup);
        formatRadioButton_RTFD.setToggleGroup(toggleGroup);
        formatRadioButton_MD.setToggleGroup(toggleGroup);
        formatRadioButton_TXT.setToggleGroup(toggleGroup);
        formatRadioButton_HTML.fire();

        // Set the inital output directory text
        updateOutputDirectory(null);
    }
}